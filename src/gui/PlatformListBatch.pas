{ PlatformListBatch — fill a list box without a table reload per row.

  LCL's Cocoa list box reloads its NSTableView on every inserted, changed
  or exchanged item (TCocoaListBoxStringList.InsertItem -> lclInsertItem
  -> reloadData + sizeToFit; TCocoaListControlStringList.Changed ->
  reloadData), even inside BeginUpdate, so filling a list is quadratic:
  5000 rows took far over 20 s. Between BeginListBatch and EndListBatch
  the table's reloadData and sizeToFit do nothing; batches nest, and the
  outermost EndListBatch runs each once. }

unit PlatformListBatch;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Controls;

procedure BeginListBatch(List: TWinControl);
procedure EndListBatch(List: TWinControl);

implementation

{$IFDEF DARWIN}
uses
  Classes, CocoaAll;

type
  TClassPtr = Pointer;
  TVoidImp = procedure(Self: id; Op: SEL); cdecl;

  { Its methods replace the table class's: skipped while batching. }
  TODListBatchHelper = objcclass(NSObject)
  public
    procedure odReloadData; message 'reloadData';
    procedure odSizeToFit; message 'sizeToFit';
  end;

function object_getClass(Obj: id): TClassPtr; cdecl; external 'objc' name 'object_getClass';
function class_getInstanceMethod(Cls: TClassPtr; Name: SEL): Pointer; cdecl;
  external 'objc' name 'class_getInstanceMethod';
function method_getImplementation(M: Pointer): Pointer; cdecl;
  external 'objc' name 'method_getImplementation';
function method_setImplementation(M: Pointer; Imp: Pointer): Pointer; cdecl;
  external 'objc' name 'method_setImplementation';

var
  Batching: TFPList = nil;
  { The table class and its own reloadData, once replaced. }
  PatchedClass: TClassPtr = nil;
  OriginalReload, OriginalSizeToFit: TVoidImp;

function InBatch(Table: Pointer): Boolean;
begin
  Result := (Batching <> nil) and (Batching.IndexOf(Table) >= 0);
end;

procedure TODListBatchHelper.odReloadData;
begin
  if not InBatch(Pointer(Self)) and Assigned(OriginalReload) then
    OriginalReload(Self, sel_registerName('reloadData'));
end;

procedure TODListBatchHelper.odSizeToFit;
begin
  if not InBatch(Pointer(Self)) and Assigned(OriginalSizeToFit) then
    OriginalSizeToFit(Self, sel_registerName('sizeToFit'));
end;

function TableOf(List: TWinControl): NSTableView;
var
  V: NSView;
begin
  Result := nil;
  if (List = nil) or not List.HandleAllocated then
    Exit;
  V := NSView(Pointer(List.Handle));
  if V.isKindOfClass(NSScrollView) then
    V := NSScrollView(V).documentView;
  if V.isKindOfClass(NSTableView) then
    Result := NSTableView(V);
end;

{ Swaps Name's implementation on Cls for the helper's, returning the one
  it replaced (nil when either is missing). }
function Swap(Cls: TClassPtr; const Name: string): TVoidImp;
var
  Mine, Theirs: Pointer;
begin
  Result := nil;
  Mine := class_getInstanceMethod(TODListBatchHelper.classClass, sel_registerName(PChar(Name)));
  Theirs := class_getInstanceMethod(Cls, sel_registerName(PChar(Name)));
  if (Mine <> nil) and (Theirs <> nil) then
    Result := TVoidImp(method_setImplementation(Theirs, method_getImplementation(Mine)));
end;

{ Patches the table's own class (LCL's TCocoaTableListView overrides
  reloadData), keeping the replaced methods to call when not batching. }
function Patch(Table: NSTableView): Boolean;
var
  Cls: TClassPtr;
begin
  Cls := object_getClass(Table);
  if PatchedClass <> nil then
    Exit(PatchedClass = Cls);
  if (class_getInstanceMethod(Cls, sel_registerName('reloadData')) = nil) or
    (class_getInstanceMethod(Cls, sel_registerName('sizeToFit')) = nil) then
    Exit(False);
  OriginalReload := Swap(Cls, 'reloadData');
  OriginalSizeToFit := Swap(Cls, 'sizeToFit');
  PatchedClass := Cls;
  Result := Assigned(OriginalReload) and Assigned(OriginalSizeToFit);
end;

procedure BeginListBatch(List: TWinControl);
var
  Table: NSTableView;
begin
  Table := TableOf(List);
  if (Table = nil) or not Patch(Table) then
    Exit;
  if Batching = nil then
    Batching := TFPList.Create;
  { One entry per open batch. }
  Batching.Add(Pointer(Table));
end;

procedure EndListBatch(List: TWinControl);
var
  Table: NSTableView;
begin
  Table := TableOf(List);
  if (Table = nil) or (Batching = nil) or (Batching.IndexOf(Pointer(Table)) < 0) then
    Exit;
  Batching.Remove(Pointer(Table));
  if Batching.IndexOf(Pointer(Table)) < 0 then
  begin
    Table.reloadData;
    Table.sizeToFit;
  end;
end;

{$ELSE}

procedure BeginListBatch(List: TWinControl);
begin
end;

procedure EndListBatch(List: TWinControl);
begin
end;

{$ENDIF}

end.
