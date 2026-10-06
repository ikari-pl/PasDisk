{ PlatformDirReader.ReadDirectory on a fixture it builds itself
  (BulkDirectoryReader.swift semantics: subdirectories listed by name,
  symlinks are leaf files and never followed, hard links share an identity,
  a device outside AllowedDevices is a crossing). }

program test_dirreader;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils, Classes, DirTypes, PlatformDirReader, PlatformFS;

var
  Fail: Boolean;
  Root: string;

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

procedure WriteBytes(const Path: string; Count: Integer);
var
  F: TFileStream;
  Data: array of Byte;
begin
  SetLength(Data, Count);
  FillChar(Data[0], Count, $33);
  F := TFileStream.Create(Path, fmCreate);
  try
    F.WriteBuffer(Data[0], Count);
  finally
    F.Free;
  end;
end;

function FileIndex(const R: TDirectoryReadResult; const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(R.Contents.Files) do
    if R.Contents.Files[I].Name = Name then
      Exit(I);
  Result := -1;
end;

function HasName(const Names: TStringDynArray; const Name: string): Boolean;
var
  N: string;
begin
  for N in Names do
    if N = Name then
      Exit(True);
  Result := False;
end;

procedure Cleanup;
begin
  DeleteFile(Root + '/flink');
  DeleteFile(Root + '/dlink');
  DeleteFile(Root + '/b');
  DeleteFile(Root + '/a.txt');
  RemoveDir(Root + '/sub');
  RemoveDir(Root);
end;

type
  TReader = function(const Path: string;
    const AllowedDevices: TDeviceSet): TDirectoryReadResult;

procedure CheckReader(Reader: TReader; const Tag: string);
var
  R: TDirectoryReadResult;
  A, B: Integer;
  Other: TDeviceSet;
begin
  R := Reader(Root, nil);
  Expect(R.Kind = drkContents, Tag + 'fixture reads as contents');
  Expect(R.Device <> 0, Tag + 'directory device is known');
  Expect((Length(R.Contents.SubdirectoryNames) = 1) and
    HasName(R.Contents.SubdirectoryNames, 'sub'), Tag + 'only the real folder is a subdirectory');
  Expect(Length(R.Contents.MountPointNames) = 0, Tag + 'no mount points');
  A := FileIndex(R, 'a.txt');
  B := FileIndex(R, 'b');
  Expect((A >= 0) and (B >= 0), Tag + 'regular file and its hard link are listed');
  if (A >= 0) and (B >= 0) then
  begin
    Expect(R.Contents.Files[A].Size >= 64 * 1024, Tag + 'file reports its allocation');
    Expect((R.Contents.Files[A].FileID = R.Contents.Files[B].FileID) and
      (R.Contents.Files[A].Device = R.Contents.Files[B].Device),
      Tag + 'hard links share device and file id');
    Expect(R.Contents.Files[A].LinkCount = 2, Tag + 'link count is 2');
  end;
  {$IFDEF UNIX}
  Expect(FileIndex(R, 'dlink') >= 0, Tag + 'directory symlink is a leaf file, not followed');
  Expect(FileIndex(R, 'flink') >= 0, Tag + 'file symlink is a leaf file');
  if FileIndex(R, 'flink') >= 0 then
    Expect(R.Contents.Files[FileIndex(R, 'flink')].Size < 64 * 1024,
      Tag + 'file symlink counts its own size, not the target''s');
  {$ENDIF}
  SetLength(Other, 1);
  Other[0] := R.Device + 1;
  Expect(Reader(Root, Other).Kind = drkCrossesDevice,
    Tag + 'a device outside AllowedDevices is a crossing');
  Expect(Reader(Root + '/missing', nil).Kind = drkUnreadable,
    Tag + 'a missing directory is unreadable');
end;

begin
  Fail := False;
  Root := ResolveRealPath(GetTempDir(False)) + '/od_dirreader_' + IntToStr(GetProcessID);
  Cleanup;
  ForceDirectories(Root + '/sub');
  try
    WriteBytes(Root + '/a.txt', 64 * 1024);
    Expect(CreateHardLink(Root + '/a.txt', Root + '/b'), 'create hard link');
    {$IFDEF UNIX}
    Expect(fpSymlink(PChar(Root + '/sub'), PChar(Root + '/dlink')) = 0, 'create directory symlink');
    Expect(fpSymlink(PChar(Root + '/a.txt'), PChar(Root + '/flink')) = 0, 'create file symlink');
    {$ENDIF}

    CheckReader(@ReadDirectory, 'host: ');
    CheckReader(@ReadDirectoryPortable, 'portable: ');
  finally
    Cleanup;
  end;
  if Fail then
    Halt(1);
  WriteLn('test_dirreader: all passed');
end.
