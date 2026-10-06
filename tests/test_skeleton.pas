program test_skeleton;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, SkeletonListing;

var
  Fail: Boolean = False;
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

function MakeSymlink(const Target, Link: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := fpSymlink(PChar(Target), PChar(Link)) = 0;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{ A file of Bytes bytes; sizes far apart so their allocated sizes differ. }
procedure WriteFile(const Path: string; Bytes: Integer);
var
  S: TFileStream;
  Buf: array of Byte;
begin
  SetLength(Buf, Bytes);
  FillChar(Buf[0], Bytes, 1);
  S := TFileStream.Create(Path, fmCreate);
  try
    S.WriteBuffer(Buf[0], Bytes);
  finally
    S.Free;
  end;
end;

procedure TestOrderAndFlags;
var
  Items: TSkeletonItems;
  I: Integer;
  Names: string;
begin
  ForceDirectories(Root + '/b');
  ForceDirectories(Root + '/A');
  ForceDirectories(Root + '/.git');
  WriteFile(Root + '/small', 100);
  WriteFile(Root + '/large', 300000);
  WriteFile(Root + '/medium', 40000);
  WriteFile(Root + '/.hidden', 50000);
  MakeSymlink(Root + '/large', Root + '/link');

  Items := ReadSkeleton(Root);
  Names := '';
  for I := 0 to High(Items) do
    Names := Names + Items[I].Name + ' ';
  Expect(Names = 'A b large medium small ',
    'folders by name, then files largest first, hidden and links left out (got ' + Names + ')');
  Expect((Length(Items) = 5) and Items[0].IsDirectory and not Items[0].SizeKnown and
    (Items[0].Size = 0), 'folders have an unknown size');
  Expect((Length(Items) = 5) and not Items[2].IsDirectory and Items[2].SizeKnown and
    (Items[2].Size > Items[3].Size) and (Items[3].Size > Items[4].Size),
    'files carry their allocated sizes');
  Expect((Length(Items) = 5) and (Items[0].Path = Root + '/A'), 'child paths');
end;

procedure TestRootAndUnreadable;
var
  Items: TSkeletonItems;
  I: Integer;
  Joined: Boolean;
begin
  Items := ReadSkeleton('/');
  Joined := Length(Items) > 0;
  for I := 0 to High(Items) do
    if (Copy(Items[I].Path, 1, 2) = '//') or (Items[I].Path <> '/' + Items[I].Name) then
      Joined := False;
  Expect(Joined, '/ lists its children as /name');
  Expect(Length(ReadSkeleton(Root + '/missing')) = 0, 'an unreadable path lists nothing');
end;

procedure Cleanup;
begin
  DeleteFile(Root + '/link');
  DeleteFile(Root + '/small');
  DeleteFile(Root + '/medium');
  DeleteFile(Root + '/large');
  DeleteFile(Root + '/.hidden');
  RemoveDir(Root + '/A');
  RemoveDir(Root + '/b');
  RemoveDir(Root + '/.git');
  RemoveDir(Root);
end;

begin
  Root := ExcludeTrailingPathDelimiter(GetTempDir(False)) + '/od_skeleton_' +
    IntToStr(GetProcessID);
  ForceDirectories(Root);
  try
    TestOrderAndFlags;
    TestRootAndUnreadable;
  finally
    Cleanup;
  end;
  if Fail then
  begin
    WriteLn('test_skeleton: FAILED');
    Halt(1);
  end;
  WriteLn('test_skeleton: all passed');
end.
