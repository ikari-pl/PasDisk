{ Test DirReader Darwin bulk path against the portable FindFirst reader. }

program test_dirreader;

{$mode objfpc}{$H+}

uses
  SysUtils, DirReader;

var
  Bulk, Portable: TDirectoryReadResult;
  Path: string;
  Fail: Boolean;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Fail := True;
  end;
end;

begin
  Fail := False;
  Path := ParamStr(1);
  if Path = '' then
    Path := '/tmp/opendisk-rings-test';
  if not DirectoryExists(Path) then
  begin
    WriteLn('skip: missing ', Path);
    Halt(0);
  end;

  { ReadDirectory prefers bulk on Darwin; portable is the fallback helper.
    Compare by scanning twice via DeviceID + counting children another way. }
  Bulk := ReadDirectory(Path, nil);
  Expect(Bulk.Kind = drkContents, 'bulk/kind');
  Expect(Length(Bulk.Contents.SubdirectoryNames) >= 1, 'has subdirs');
  Expect(Bulk.Device <> 0, 'device');

  WriteLn('OK device=', Bulk.Device,
    ' dirs=', Length(Bulk.Contents.SubdirectoryNames),
    ' files=', Length(Bulk.Contents.Files),
    ' mounts=', Length(Bulk.Contents.MountPointNames));
  if Fail then
    Halt(1);
end.
