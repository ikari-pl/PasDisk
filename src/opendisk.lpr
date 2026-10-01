{ OpenDisk CLI — scan a path and list the largest children. }

program opendisk;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, FileTree, Traversal, Formatters;

var
  LastProgressAt: QWord;

procedure OnProgress(BytesScanned: Int64; ItemsScanned: Integer);
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if (Now - LastProgressAt) < 200 then
    Exit;
  LastProgressAt := Now;
  Write(Format(#13'Scanning: %s (%d items)',
    [FormatFileSize(BytesScanned), ItemsScanned]));
  Flush(Output);
end;

procedure PrintUsage;
begin
  WriteLn('OpenDisk — cross-platform disk usage scanner');
  WriteLn('Usage:');
  WriteLn('  opendisk scan <path>   Scan a directory or volume');
  WriteLn('  opendisk version       Print version');
end;

procedure CmdScan(const Path: string);
var
  Tree: TFileTree;
  Children: TFPList;
  I: Integer;
  ID: TNodeID;
  Limit: Integer;
  Expanded: string;
begin
  Expanded := ExpandFileName(Path);
  if not DirectoryExists(Expanded) then
  begin
    WriteLn(StdErr, 'Not a directory: ', Expanded);
    Halt(1);
  end;

  WriteLn('Scanning ', Expanded, ' …');
  LastProgressAt := 0;
  Tree := ScanPath(Expanded, @OnProgress);
  try
    Write(#13, StringOfChar(' ', 60), #13);
    WriteLn('Total: ', FormatFileSize(Tree.SizeOf(RootID)),
      '  (', Tree.NodeCount - 1, ' items)');
    WriteLn;
    Children := TFPList.Create;
    try
      Tree.ChildrenSortedForDisplay(RootID, Children);
      Limit := Children.Count;
      if Limit > 40 then
        Limit := 40;
      for I := 0 to Limit - 1 do
      begin
        ID := TNodeID(PtrInt(Children[I]));
        WriteLn(Format('%10s  %s%s',
          [FormatFileSize(Tree.SizeOf(ID)),
           Tree.NameOf(ID),
           BoolToStr(Tree.IsDirectory(ID), '/', '')]));
      end;
      if Children.Count > Limit then
        WriteLn('… and ', Children.Count - Limit, ' more');
    finally
      Children.Free;
    end;
  finally
    Tree.Free;
  end;
end;

begin
  if ParamCount < 1 then
  begin
    PrintUsage;
    Halt(1);
  end;

  case LowerCase(ParamStr(1)) of
    'scan':
      begin
        if ParamCount < 2 then
        begin
          WriteLn(StdErr, 'scan requires a path');
          Halt(1);
        end;
        CmdScan(ParamStr(2));
      end;
    'version', '-v', '--version':
      WriteLn('opendisk 0.1.0-dev (pascal)');
    'help', '-h', '--help':
      PrintUsage;
  else
    WriteLn(StdErr, 'Unknown command: ', ParamStr(1));
    PrintUsage;
    Halt(1);
  end;
end.
