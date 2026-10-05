{ ScanCache — persist FileTree + FSEvents header beside the app caches.

  Binary layout matches OpenDisk ScanCache.swift (format version 3) so a
  later rescan can apply FSEvents deltas instead of walking again. }

unit ScanCache;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileTree, DirReader;

type
  TScanCacheHeader = record
    EventID: QWord;
    CapturedAt: Double;      { Unix seconds }
    FullScanSeconds: Double;
  end;

  TScanCacheEntry = record
    Tree: TFileTree;
    Header: TScanCacheHeader;
    OK: Boolean;
  end;

function ScanCacheSave(Tree: TFileTree; const RootPath: string;
  const Header: TScanCacheHeader): Boolean;
function ScanCacheLoad(const RootPath: string): TScanCacheEntry;
function ScanCachePeek(const RootPath: string; out Header: TScanCacheHeader;
  out FileBytes: Int64): Boolean;
function ScanCacheFilePath(const RootPath: string): string;

{ Evict old caches in Dir, never touching KeepPath (ScanCache.swift:117-145).
  Exposed so tests can exercise the caps without writing 4 GiB. }
procedure ScanCachePrune(const Dir, KeepPath: string; MaxFiles: Integer;
  MaxBytes: Int64);

{ Reads and checks the cache header for RootPath; False on any mismatch or
  malformed header. Exposed so tests can feed crafted streams. }
function ParseHeader(Stream: TStream; const RootPath: string;
  out Header: TScanCacheHeader): Boolean;

{ Override the cache directory (tests only); '' restores the default. }
procedure ScanCacheSetDirectory(const Dir: string);

implementation

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

const
  FormatVersion: LongWord = 3;
  { ScanCache.swift:114-115 }
  MaxCacheFiles = 8;
  MaxCacheBytes: Int64 = Int64(4) shl 30;
  { Orphaned .tmp files older than this are removed (ScanCache.swift:127). }
  StaleTempSeconds = 3600;

var
  DirectoryOverride: string = '';

function FNV1a64(const S: string): QWord;
var
  Raw: RawByteString;
  I: Integer;
begin
  Raw := RawByteString(S);
  Result := QWord($cbf29ce484222325);
  for I := 1 to Length(Raw) do
  begin
    Result := Result xor QWord(Byte(Raw[I]));
    Result := Result * QWord($00000100000001B3);
  end;
end;

procedure ScanCacheSetDirectory(const Dir: string);
begin
  DirectoryOverride := Dir;
end;

function CacheDirectory: string;
begin
  if DirectoryOverride <> '' then
    Exit(ExcludeTrailingPathDelimiter(DirectoryOverride));
  {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(GetUserDir) +
    'Library/Caches/opendisk/ScanCache';
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'ScanCache';
  {$ENDIF}
end;

function ScanCacheFilePath(const RootPath: string): string;
begin
  Result := IncludeTrailingPathDelimiter(CacheDirectory) +
    IntToHex(FNV1a64(RootPath), 16) + '.dmscan';
end;

procedure WriteU32(Stream: TStream; Value: LongWord);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

procedure WriteU64(Stream: TStream; Value: QWord);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

procedure WriteF64(Stream: TStream; Value: Double);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;

function ReadU32(Stream: TStream): LongWord;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

function ReadU64(Stream: TStream): QWord;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

function ReadF64(Stream: TStream): Double;
begin
  Stream.ReadBuffer(Result, SizeOf(Result));
end;

{ Modification time (Unix seconds) and size; False if the entry vanished. }
function CacheFileInfo(const Path: string; out Modified: Double;
  out Size: Int64): Boolean;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  Result := fpStat(Path, Info) = 0;
  if not Result then
    Exit;
  Modified := Double(Info.st_mtime) + Double(Info.st_mtimensec) / Double(1e9);
  Size := Info.st_size;
end;
{$ELSE}
var
  Rec: TSearchRec;
begin
  Result := FindFirst(Path, faAnyFile, Rec) = 0;
  if not Result then
    Exit;
  Modified := (Rec.TimeStamp - UnixDateDelta) * SecsPerDay;
  Size := Rec.Size;
  FindClose(Rec);
end;
{$ENDIF}

type
  TCacheFile = record
    Path: string;
    Modified: Double;
    Size: Int64;
  end;

procedure ScanCachePrune(const Dir, KeepPath: string; MaxFiles: Integer;
  MaxBytes: Int64);
var
  Rec: TSearchRec;
  Base, Path, Ext: string;
  Caches: array of TCacheFile;
  Item: TCacheFile;
  Count, I, J, Kept: Integer;
  Modified, Now: Double;
  Size, Bytes: Int64;
begin
  Base := IncludeTrailingPathDelimiter(Dir);
  {$IFDEF UNIX}
  Now := fpTime;
  {$ELSE}
  Now := (SysUtils.Now - UnixDateDelta) * SecsPerDay;
  {$ENDIF}
  Count := 0;
  SetLength(Caches, 0);
  if FindFirst(Base + '*', faAnyFile, Rec) <> 0 then
    Exit;
  try
    repeat
      if (Rec.Name = '.') or (Rec.Name = '..') then
        Continue;
      Path := Base + Rec.Name;
      { Swift defaults a missing date to .distantPast and size to 0. }
      if not CacheFileInfo(Path, Modified, Size) then
      begin
        Modified := -1e300;
        Size := 0;
      end;
      Ext := ExtractFileExt(Rec.Name);
      if Ext = '.tmp' then
      begin
        { ScanCache.swift:126-131 — drop orphaned temp files older than 1 h. }
        if Modified < Now - StaleTempSeconds then
          DeleteFile(Path);
        Continue;
      end;
      if Ext <> '.dmscan' then
        Continue;
      if Count = Length(Caches) then
        SetLength(Caches, Count * 2 + 8);
      Caches[Count].Path := Path;
      Caches[Count].Modified := Modified;
      Caches[Count].Size := Size;
      Inc(Count);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;

  { Newest first (ScanCache.swift:136). }
  for I := 1 to Count - 1 do
  begin
    Item := Caches[I];
    J := I - 1;
    while (J >= 0) and (Caches[J].Modified < Item.Modified) do
    begin
      Caches[J + 1] := Caches[J];
      Dec(J);
    end;
    Caches[J + 1] := Item;
  end;

  { ScanCache.swift:137-145 — every entry counts toward the running totals,
    evicted or not; the file just written is never removed. }
  Kept := 0;
  Bytes := 0;
  for I := 0 to Count - 1 do
  begin
    Inc(Kept);
    Inc(Bytes, Caches[I].Size);
    if ((Kept > MaxFiles) or (Bytes > MaxBytes)) and
       (Caches[I].Path <> KeepPath) then
      DeleteFile(Caches[I].Path);
  end;
end;

function ScanCacheSave(Tree: TFileTree; const RootPath: string;
  const Header: TScanCacheHeader): Boolean;
var
  Dir, FinalPath, TmpPath: string;
  Stream: TFileStream;
  Device: QWord;
  PathBytes: RawByteString;
begin
  Result := False;
  if Tree = nil then
    Exit;
  Device := DeviceIDOfPath(RootPath);
  if Device = 0 then
    Exit;
  Dir := CacheDirectory;
  ForceDirectories(Dir);
  FinalPath := ScanCacheFilePath(RootPath);
  TmpPath := IncludeTrailingPathDelimiter(Dir) + Format('%16.16x.tmp', [GetTickCount64]);
  Stream := TFileStream.Create(TmpPath, fmCreate);
  try
    WriteU32(Stream, FormatVersion);
    WriteU64(Stream, Header.EventID);
    WriteF64(Stream, Header.CapturedAt);
    WriteF64(Stream, Header.FullScanSeconds);
    WriteU64(Stream, Device);
    PathBytes := RawByteString(RootPath);
    WriteU32(Stream, LongWord(Length(PathBytes)));
    if Length(PathBytes) > 0 then
      Stream.WriteBuffer(PathBytes[1], Length(PathBytes));
    Tree.WriteSerialized(Stream);
  finally
    Stream.Free;
  end;
  if FileExists(FinalPath) then
    DeleteFile(FinalPath);
  Result := RenameFile(TmpPath, FinalPath);
  if Result then
    ScanCachePrune(Dir, FinalPath, MaxCacheFiles, MaxCacheBytes)
  else
    DeleteFile(TmpPath);
end;

function ParseHeader(Stream: TStream; const RootPath: string;
  out Header: TScanCacheHeader): Boolean;
var
  Version, PathLen: LongWord;
  SavedDevice: QWord;
  PathBytes: RawByteString;
  SavedPath: string;
  LiveDevice: QWord;

  function Left: Int64;
  begin
    Result := Stream.Size - Stream.Position;
  end;

begin
  Result := False;
  { ScanCache.swift parseHeader: every field and the saved path must fit
    in the file; a short or corrupt header is a cache miss. }
  if Left < 4 + 8 + 8 + 8 + 8 + 4 then
    Exit;
  Version := ReadU32(Stream);
  if Version <> FormatVersion then
    Exit;
  Header.EventID := ReadU64(Stream);
  Header.CapturedAt := ReadF64(Stream);
  Header.FullScanSeconds := ReadF64(Stream);
  SavedDevice := ReadU64(Stream);
  PathLen := ReadU32(Stream);
  if (PathLen > LongWord(High(Integer))) or (Int64(PathLen) > Left) then
    Exit;
  SetLength(PathBytes, PathLen);
  if PathLen > 0 then
    Stream.ReadBuffer(PathBytes[1], PathLen);
  SavedPath := string(PathBytes);
  if SavedPath <> RootPath then
    Exit;
  LiveDevice := DeviceIDOfPath(RootPath);
  if (LiveDevice = 0) or (LiveDevice <> SavedDevice) then
    Exit;
  Result := True;
end;

function ScanCachePeek(const RootPath: string; out Header: TScanCacheHeader;
  out FileBytes: Int64): Boolean;
var
  Path: string;
  Stream: TFileStream;
begin
  Result := False;
  FileBytes := 0;
  FillChar(Header, SizeOf(Header), 0);
  Path := ScanCacheFilePath(RootPath);
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    FileBytes := Stream.Size;
    Result := ParseHeader(Stream, RootPath, Header);
  finally
    Stream.Free;
  end;
end;

function ScanCacheLoad(const RootPath: string): TScanCacheEntry;
var
  Path: string;
  Stream: TFileStream;
begin
  Result.OK := False;
  Result.Tree := nil;
  FillChar(Result.Header, SizeOf(Result.Header), 0);
  Path := ScanCacheFilePath(RootPath);
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    if not ParseHeader(Stream, RootPath, Result.Header) then
      Exit;
    Result.Tree := TFileTree.LoadSerialized(Stream);
    Result.OK := Result.Tree <> nil;
    if not Result.OK then
      FreeAndNil(Result.Tree);
  finally
    Stream.Free;
  end;
end;

end.
