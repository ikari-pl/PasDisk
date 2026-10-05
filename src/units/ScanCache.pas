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

implementation

const
  FormatVersion: LongWord = 3;
  MaxCacheFiles = 8;

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

function CacheDirectory: string;
begin
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
  if not Result then
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
begin
  Result := False;
  Version := ReadU32(Stream);
  if Version <> FormatVersion then
    Exit;
  Header.EventID := ReadU64(Stream);
  Header.CapturedAt := ReadF64(Stream);
  Header.FullScanSeconds := ReadF64(Stream);
  SavedDevice := ReadU64(Stream);
  PathLen := ReadU32(Stream);
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
