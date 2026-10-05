{ Collector — staged deletions with undo and protected-path guards.

  Port of OpenDisk Models/Collector.swift: undo is recorded only when the
  staged items actually change; deletion removes links themselves, never
  their targets, and keeps items that failed so the user can retry. }

unit Collector;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ProtectedPaths, PlatformRemove;

type
  TCollectedFile = class
  public
    Path: string;
    Name: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;

  TCollector = class
  private
    FItems: TFPList;
    FUndo: TFPList;
    FBlockedNotice: string;
    FFailures: TStringList;
    procedure FreeItems(List: TFPList);
    procedure PushUndo;
    function IndexOfPath(const Path: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Add(const Path, Name: string; Size: Int64; IsDirectory: Boolean): Boolean;
    procedure Remove(const Path: string);
    function Undo: Boolean;
    function CanUndo: Boolean;
    function UndoCount: Integer;
    function Contains(const Path: string): Boolean;
    function Count: Integer;
    function TotalBytes: Int64;
    { Permanently removes every staged item; returns bytes freed by the
      successful removals. Failed items stay staged and are listed in
      Failures as "path<TAB>reason". }
    function DeleteAll: Int64;
    property Items: TFPList read FItems;
    property Failures: TStringList read FFailures;
    property BlockedNotice: string read FBlockedNotice;
  end;

implementation

constructor TCollector.Create;
begin
  inherited Create;
  FItems := TFPList.Create;
  FUndo := TFPList.Create;
  FFailures := TStringList.Create;
end;

destructor TCollector.Destroy;
begin
  Clear;
  FreeItems(FUndo);
  FUndo.Free;
  FItems.Free;
  FFailures.Free;
  inherited Destroy;
end;

procedure TCollector.FreeItems(List: TFPList);
var
  I: Integer;
begin
  for I := 0 to List.Count - 1 do
    TObject(List[I]).Free;
  List.Clear;
end;

procedure TCollector.Clear;
begin
  FBlockedNotice := '';
  { recordingUndo: clearing an empty collector is not a change. }
  if FItems.Count = 0 then
    Exit;
  PushUndo;
  FreeItems(FItems);
  FBlockedNotice := '';
end;

function TCollector.IndexOfPath(const Path: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if TCollectedFile(FItems[I]).Path = Path then
      Exit(I);
  Result := -1;
end;

function TCollector.Contains(const Path: string): Boolean;
begin
  Result := IndexOfPath(Path) >= 0;
end;

procedure TCollector.PushUndo;
var
  Snapshot: TFPList;
  I: Integer;
  Src, Dst: TCollectedFile;
begin
  Snapshot := TFPList.Create;
  for I := 0 to FItems.Count - 1 do
  begin
    Src := TCollectedFile(FItems[I]);
    Dst := TCollectedFile.Create;
    Dst.Path := Src.Path;
    Dst.Name := Src.Name;
    Dst.Size := Src.Size;
    Dst.IsDirectory := Src.IsDirectory;
    Snapshot.Add(Dst);
  end;
  FUndo.Add(Snapshot);
  if FUndo.Count > 50 then
  begin
    FreeItems(TFPList(FUndo[0]));
    TFPList(FUndo[0]).Free;
    FUndo.Delete(0);
  end;
end;

function TCollector.Add(const Path, Name: string; Size: Int64;
  IsDirectory: Boolean): Boolean;
var
  Reason: string;
  Item: TCollectedFile;
  I: Integer;
  Existing: TCollectedFile;
begin
  Result := False;
  FBlockedNotice := '';
  if (Path = '') or (Copy(Path, 1, 2) = '::') then
    Exit;
  if not (FileExists(Path) or DirectoryExists(Path)) then
    Exit;
  Reason := ProtectedReason(Path);
  if Reason <> '' then
  begin
    FBlockedNotice := '"' + Name + '" ' + Reason;
    Exit;
  end;
  if Contains(Path) then
    Exit;
  for I := 0 to FItems.Count - 1 do
  begin
    Existing := TCollectedFile(FItems[I]);
    if Existing.IsDirectory and
       (Copy(Path, 1, Length(Existing.Path) + 1) = Existing.Path + DirectorySeparator) then
      Exit;
  end;
  PushUndo;
  if IsDirectory then
  begin
    I := 0;
    while I < FItems.Count do
    begin
      Existing := TCollectedFile(FItems[I]);
      if Copy(Existing.Path, 1, Length(Path) + 1) = Path + DirectorySeparator then
      begin
        Existing.Free;
        FItems.Delete(I);
      end
      else
        Inc(I);
    end;
  end;
  Item := TCollectedFile.Create;
  Item.Path := Path;
  Item.Name := Name;
  Item.Size := Size;
  Item.IsDirectory := IsDirectory;
  FItems.Add(Item);
  Result := True;
end;

procedure TCollector.Remove(const Path: string);
var
  Idx: Integer;
begin
  Idx := IndexOfPath(Path);
  if Idx < 0 then
    Exit;
  PushUndo;
  TCollectedFile(FItems[Idx]).Free;
  FItems.Delete(Idx);
end;

function TCollector.Undo: Boolean;
var
  Snapshot: TFPList;
begin
  Result := False;
  if FUndo.Count = 0 then
    Exit;
  FreeItems(FItems);
  Snapshot := TFPList(FUndo[FUndo.Count - 1]);
  FUndo.Delete(FUndo.Count - 1);
  while Snapshot.Count > 0 do
  begin
    FItems.Add(Snapshot[0]);
    Snapshot.Delete(0);
  end;
  Snapshot.Free;
  Result := True;
end;

function TCollector.CanUndo: Boolean;
begin
  Result := FUndo.Count > 0;
end;

function TCollector.UndoCount: Integer;
begin
  Result := FUndo.Count;
end;

function TCollector.Count: Integer;
begin
  Result := FItems.Count;
end;

function TCollector.TotalBytes: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FItems.Count - 1 do
    Result := Result + TCollectedFile(FItems[I]).Size;
end;

function TCollector.DeleteAll: Int64;
var
  I: Integer;
  Item: TCollectedFile;
  Error: string;
begin
  Result := 0;
  FFailures.Clear;
  I := 0;
  while I < FItems.Count do
  begin
    Item := TCollectedFile(FItems[I]);
    if RemoveItem(Item.Path, Error) then
    begin
      Result := Result + Item.Size;
      Item.Free;
      FItems.Delete(I);
    end
    else
    begin
      FFailures.Add(Item.Path + #9 + Error);
      Inc(I);
    end;
  end;
  while FUndo.Count > 0 do
  begin
    FreeItems(TFPList(FUndo[0]));
    TFPList(FUndo[0]).Free;
    FUndo.Delete(0);
  end;
end;

end.
