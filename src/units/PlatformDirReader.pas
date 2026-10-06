{ PlatformDirReader — list one directory, per OS.

  Darwin uses getattrlistbulk (ported from OpenDisk
  BulkDirectoryReader.swift); elsewhere SysUtils.FindFirst with lstat
  metadata. Result types live in DirTypes. }

unit PlatformDirReader;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DirTypes, PlatformVolumes, PlatformFS;

{ BulkDirectoryReader.read(directoryAt:allowedDevices:): a directory on a
  device outside AllowedDevices reports drkCrossesDevice. }
function ReadDirectory(const Path: string;
  const AllowedDevices: TDeviceSet): TDirectoryReadResult;

{ The FindFirst + lstat reader every non-Darwin platform uses. Exposed so
  tests on macOS exercise it against the getattrlistbulk reader. }
function ReadDirectoryPortable(const Path: string;
  const AllowedDevices: TDeviceSet): TDirectoryReadResult;

implementation

{$IFDEF UNIX}
uses
  BaseUnix, Unix;
{$ENDIF}
{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

{$IFDEF DARWIN}
const
  { sys/attr.h + sys/fcntl.h — values verified against macOS SDK }
  ATTR_BIT_MAP_COUNT = 5;
  ATTR_CMN_RETURNED_ATTRS = $80000000;
  ATTR_CMN_NAME = $00000001;
  ATTR_CMN_OBJTYPE = $00000008;
  ATTR_CMN_FILEID = $02000000;
  ATTR_DIR_MOUNTSTATUS = $00000004;
  ATTR_FILE_LINKCOUNT = $00000001;
  ATTR_FILE_ALLOCSIZE = $00000004;
  VTYPE_DIR = 2;
  DarwinODirectory = $00100000;
  DarwinONoFollow = $00000100;
  BulkBufferSize = 256 * 1024;

type
  attrgroup_t = LongWord;
  TAttrList = packed record
    bitmapcount: Word;
    reserved: Word;
    commonattr: attrgroup_t;
    volattr: attrgroup_t;
    dirattr: attrgroup_t;
    fileattr: attrgroup_t;
    forkattr: attrgroup_t;
  end;

function getattrlistbulk(dirfd: cint; var attrList: TAttrList;
  attrBuf: Pointer; attrBufSize: csize_t; options: QWord): cint; cdecl;
  external 'c' name 'getattrlistbulk';
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

function ReadDirectoryPortable(const Path: string;
  const AllowedDevices: TDeviceSet): TDirectoryReadResult;
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

  Result.Device := VolumeDeviceOf(Path);
  if Result.Device = 0 then
    Exit;
  if (Length(AllowedDevices) > 0) and not DeviceInSet(AllowedDevices, Result.Device) then
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
        { BulkDirectoryReader.swift: a symlink is a leaf file entry with its
          own allocation, never followed, whatever it points at. }
        { FindFirst attributes follow links, so ask lstat. }
        if ((Search.Attr and faDirectory) <> 0) and not IsSymLink(ChildPath) then
        begin
          ChildDev := VolumeDeviceOf(ChildPath);
          if (ChildDev <> 0) and (ChildDev <> Result.Device) then
            AppendName(Result.Contents.MountPointNames, Search.Name)
          else
            AppendName(Result.Contents.SubdirectoryNames, Search.Name);
        end
        else
        begin
          Entry.Name := Search.Name;
          Entry.Size := EntryAllocatedSize(ChildPath);
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

{$IFDEF DARWIN}
function LoadU32(Buf: PByte; Off: Integer): LongWord;
begin
  Move(Buf[Off], Result, SizeOf(Result));
end;

function LoadI32(Buf: PByte; Off: Integer): LongInt;
begin
  Move(Buf[Off], Result, SizeOf(Result));
end;

function LoadU64(Buf: PByte; Off: Integer): QWord;
begin
  Move(Buf[Off], Result, SizeOf(Result));
end;

function LoadI64(Buf: PByte; Off: Integer): Int64;
begin
  Move(Buf[Off], Result, SizeOf(Result));
end;

procedure ParseBulkRecord(Rec: PByte; Len: Integer; DirDevice: QWord;
  var Contents: TDirectoryContents);
var
  ReturnedCommon, ReturnedDir, ReturnedFile: LongWord;
  NameDataOffset, NameLength, NameStart, Offset: Integer;
  IsDirectory: Boolean;
  FileID: QWord;
  MountStatus, LinkCount: LongWord;
  Size: Int64;
  Name: string;
  Entry: TDirFileEntry;
begin
  if Len < 36 then
    Exit;

  ReturnedCommon := LoadU32(Rec, 4);
  ReturnedDir := LoadU32(Rec, 12);
  ReturnedFile := LoadU32(Rec, 16);

  NameDataOffset := LoadI32(Rec, 24);
  NameLength := Integer(LoadU32(Rec, 28)) - 1;
  NameStart := 24 + NameDataOffset;
  if (NameLength <= 0) or (NameLength >= 1024) or (NameStart + NameLength > Len) then
    Exit;

  { Skip "." and ".." }
  if NameLength <= 2 then
  begin
    if Rec[NameStart] = Ord('.') then
    begin
      if NameLength = 1 then
        Exit;
      if Rec[NameStart + 1] = Ord('.') then
        Exit;
    end;
  end;

  Offset := 32;
  IsDirectory := False;
  if (ReturnedCommon and ATTR_CMN_OBJTYPE) <> 0 then
  begin
    if Offset + 4 > Len then
      Exit;
    IsDirectory := LoadU32(Rec, Offset) = VTYPE_DIR;
    Inc(Offset, 4);
  end;

  FileID := 0;
  if (ReturnedCommon and ATTR_CMN_FILEID) <> 0 then
  begin
    if Offset + 8 > Len then
      Exit;
    FileID := LoadU64(Rec, Offset);
    Inc(Offset, 8);
  end;

  SetString(Name, PChar(@Rec[NameStart]), NameLength);

  if IsDirectory then
  begin
    MountStatus := 0;
    if (ReturnedDir and ATTR_DIR_MOUNTSTATUS) <> 0 then
    begin
      if Offset + 4 > Len then
        Exit;
      MountStatus := LoadU32(Rec, Offset);
    end;
    if MountStatus <> 0 then
      AppendName(Contents.MountPointNames, Name)
    else
      AppendName(Contents.SubdirectoryNames, Name);
    Exit;
  end;

  LinkCount := 1;
  if (ReturnedFile and ATTR_FILE_LINKCOUNT) <> 0 then
  begin
    if Offset + 4 > Len then
      Exit;
    LinkCount := LoadU32(Rec, Offset);
    Inc(Offset, 4);
  end;

  Size := 0;
  if (ReturnedFile and ATTR_FILE_ALLOCSIZE) <> 0 then
  begin
    if Offset + 8 > Len then
      Exit;
    Size := LoadI64(Rec, Offset);
    if (Size < 0) or (Size > 1000000000000000) then
      Size := 0;
  end;

  Entry.Name := Name;
  Entry.Size := Size;
  Entry.FileID := FileID;
  Entry.LinkCount := LinkCount;
  Entry.Device := DirDevice;
  AppendFile(Contents, Entry);
end;

function ReadDirectoryDarwin(const Path: string;
  const AllowedDevices: TDeviceSet): TDirectoryReadResult;
var
  Fd: cint;
  Info: BaseUnix.Stat;
  Request: TAttrList;
  Buffer: PByte;
  Count, I, Offset, RecLen: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := drkUnreadable;
  SetLength(Result.Contents.Files, 0);
  SetLength(Result.Contents.SubdirectoryNames, 0);
  SetLength(Result.Contents.MountPointNames, 0);

  Fd := FpOpen(Path, O_RdOnly or DarwinODirectory or DarwinONoFollow);
  if Fd < 0 then
    Exit;
  try
    if FpFStat(Fd, Info) <> 0 then
      Exit;
    Result.Device := QWord(Info.st_dev);
    if (Length(AllowedDevices) > 0) and
       not DeviceInSet(AllowedDevices, Result.Device) then
    begin
      Result.Kind := drkCrossesDevice;
      Exit;
    end;

    FillChar(Request, SizeOf(Request), 0);
    Request.bitmapcount := ATTR_BIT_MAP_COUNT;
    Request.commonattr := ATTR_CMN_RETURNED_ATTRS or ATTR_CMN_NAME or
      ATTR_CMN_OBJTYPE or ATTR_CMN_FILEID;
    Request.dirattr := ATTR_DIR_MOUNTSTATUS;
    Request.fileattr := ATTR_FILE_LINKCOUNT or ATTR_FILE_ALLOCSIZE;

    Buffer := GetMem(BulkBufferSize);
    try
      Result.Kind := drkContents;
      while True do
      begin
        Count := getattrlistbulk(Fd, Request, Buffer, BulkBufferSize, 0);
        if Count <= 0 then
          Break;
        Offset := 0;
        for I := 0 to Count - 1 do
        begin
          if Offset + 4 > BulkBufferSize then
            Break;
          RecLen := Integer(LoadU32(Buffer, Offset));
          if (RecLen <= 0) or (Offset + RecLen > BulkBufferSize) then
            Break;
          ParseBulkRecord(@Buffer[Offset], RecLen, Result.Device, Result.Contents);
          Inc(Offset, RecLen);
        end;
      end;
    finally
      FreeMem(Buffer);
    end;
  finally
    FpClose(Fd);
  end;
end;
{$ENDIF}

function ReadDirectory(const Path: string;
  const AllowedDevices: TDeviceSet): TDirectoryReadResult;
begin
  {$IFDEF DARWIN}
  Result := ReadDirectoryDarwin(Path, AllowedDevices);
  if Result.Kind = drkUnreadable then
    Result := ReadDirectoryPortable(Path, AllowedDevices);
  {$ELSE}
  Result := ReadDirectoryPortable(Path, AllowedDevices);
  {$ENDIF}
end;

end.
