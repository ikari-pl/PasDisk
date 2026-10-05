{ Round-trip FileTree serialization used by ScanCache. }

program test_scancache;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, FileTree, Traversal, ScanCache;

var
  Tree, Loaded: TFileTree;
  Stream: TMemoryStream;
  Entry: TScanCacheEntry;
  Header: TScanCacheHeader;
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

  Tree := ScanPath(Path);
  try
    Stream := TMemoryStream.Create;
    try
      Tree.WriteSerialized(Stream);
      Stream.Position := 0;
      Loaded := TFileTree.LoadSerialized(Stream);
      Expect(Loaded <> nil, 'load');
      if Loaded <> nil then
      try
        Expect(Loaded.NodeCount = Tree.NodeCount, 'node count');
        Expect(Loaded.SizeOf(RootID) = Tree.SizeOf(RootID), 'root size');
        Expect(Loaded.NameOf(RootID) = Tree.NameOf(RootID), 'root name');
      finally
        Loaded.Free;
      end;
    finally
      Stream.Free;
    end;

    Header.EventID := 42;
    Header.CapturedAt := 1;
    Header.FullScanSeconds := 0.5;
    Expect(ScanCacheSave(Tree, Tree.NameOf(RootID), Header), 'save');
    Entry := ScanCacheLoad(Tree.NameOf(RootID));
    Expect(Entry.OK, 'cache load');
    if Entry.OK then
    try
      Expect(Entry.Header.EventID = 42, 'event id');
      Expect(Entry.Tree.SizeOf(RootID) = Tree.SizeOf(RootID), 'cached size');
    finally
      Entry.Tree.Free;
    end;
  finally
    Tree.Free;
  end;

  if Fail then
    Halt(1);
  WriteLn('OK scan-cache round trip');
end.
