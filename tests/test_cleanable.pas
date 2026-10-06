{ CleanableSpace: DiskAnalyzer.swift cleanableCacheEntries and the
  "Purgeable Space" summary. }

program test_cleanable;

{$mode objfpc}{$H+}

uses
  SysUtils, FileTree, PlatformCacheCatalog, CleanableSpace;

var
  Failures: Integer;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('ok: ', Msg)
  else
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end;
end;

function Loc(const Name, Path: string): TCacheLocation;
begin
  Result.Name := Name;
  Result.Path := Path;
end;

procedure TestEntries;
var
  Tree: TFileTree;
  Lib, Caches, Brew, Logs, Npm: TNodeID;
  Locations: TCacheLocations;
  E, S: TCleanableEntries;
begin
  Tree := TFileTree.Create('/Users/me');
  try
    Lib := Tree.AddNode('Library', RootID, 0, True);
    Caches := Tree.AddNode('Caches', Lib, 0, True);
    Brew := Tree.AddNode('Homebrew', Caches, 0, True);
    Tree.AddNode('bottle.tar.gz', Brew, 300, False);
    Logs := Tree.AddNode('Logs', Lib, 0, True);
    Tree.AddNode('a.log', Logs, 300, False);
    Npm := Tree.AddNode('.npm', RootID, 0, True);
    Tree.AddNode('_cacache', Npm, 0, True);
    Tree.AddNode('.Trash', RootID, 50, False);
    Tree.AddNode('big', Lib, 900, False);
    Tree.RollUpDirectorySizes;

    SetLength(Locations, 5);
    Locations[0] := Loc('User Logs', '/Users/me/Library/Logs');
    Locations[1] := Loc('npm Cache', '/Users/me/.npm/_cacache');
    Locations[2] := Loc('Homebrew Cache', '/Users/me/Library/Caches/Homebrew');
    Locations[3] := Loc('Trash', '/Users/me/.Trash');
    Locations[4] := Loc('System Caches', '/Library/Caches');
    E := CleanableCacheEntries(Tree, '/Users/me', Locations);
    Expect(Length(E) = 2, Format('only non-empty directories inside the scan (%d)', [Length(E)]));
    Expect((Length(E) = 2) and (E[0].Name = 'User Logs') and (E[1].Name = 'Homebrew Cache'),
      'catalogue order is kept');
    Expect((Length(E) = 2) and (E[1].Path = '/Users/me/Library/Caches/Homebrew') and
      (E[1].Size = 300), 'entry carries path and rolled-up size');
    Expect(CleanableTotal(E) = 600, 'summary size is the sum');
    S := SortedForDisplay(E);
    Expect((S[0].Name = 'Homebrew Cache') and (S[1].Name = 'User Logs'),
      'display order: size, then name');
    Expect(Length(CleanableCacheEntries(nil, '/', Locations)) = 0, 'no tree, no entries');
  finally
    Tree.Free;
  end;
end;

procedure TestCatalog;
var
  C: TCacheLocations;
begin
  C := CleanableCacheLocations;
  {$IFDEF DARWIN}
  Expect(Length(C) = 23, Format('macOS catalogue has the 23 Swift entries (%d)', [Length(C)]));
  Expect((C[0].Name = 'Homebrew Cache') and (Pos('/Library/Caches/Homebrew', C[0].Path) > 1) and
    (C[0].Path[1] = '/'), 'home entries are absolute: ' + C[0].Path);
  Expect((C[22].Name = 'System Caches') and (C[22].Path = '/Library/Caches'),
    'System Caches is the absolute /Library/Caches');
  {$ELSE}
  Expect(Length(C) = 0, 'no catalogue outside macOS');
  {$ENDIF}
  Expect(HiddenSpaceSentinelPath = '::Purgeable Space', 'sentinel path matches Swift');
end;

begin
  Failures := 0;
  TestEntries;
  TestCatalog;
  if Failures > 0 then
  begin
    WriteLn('test_cleanable: ', Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('test_cleanable: all passed');
end.
