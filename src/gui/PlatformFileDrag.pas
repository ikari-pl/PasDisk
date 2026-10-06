{ PlatformFileDrag — native file drags inside the app (Utilities/FileDrag.swift).

  FileDragSource: a drag of one or more files that also exports their
  file URLs (Finder can take them) unless ExportFileURLs is off; the drag
  image is FileDragLabel (icon, name, size). InAppFileDropDelegate: a drop
  zone that accepts only drags this app started, proposing a copy.

  Three entry points: BeginFileDrag from a control's mouse-move handler
  (ring segments, collector rows), EnableListRowDrag for a list box (the
  table view drags its rows natively, Finder-style), and RegisterDropZone
  for the view that takes the drops. Screen points are LCL screen
  coordinates (top-left origin). }

unit PlatformFileDrag;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, SysUtils, Controls, Types;

type
  TDragItem = record
    Path: string;
    Name: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;
  TDragItems = array of TDragItem;

  { Accepted: the drop was taken (operation not empty). }
  TDragEndedEvent = procedure(const ScreenPt: TPoint; Accepted: Boolean) of object;
  TRowDragItemFunc = function(Row: Integer; out Item: TDragItem): Boolean of object;
  TRowsDragBeganEvent = procedure(const Rows: array of Integer) of object;
  TDropZoneEvent = function(const ScreenPt: TPoint): Boolean of object;
  TDropExitEvent = procedure of object;

{ Starts a drag of Items from Source; call from a mouse-move handler with
  the left button down. False when no drag could start. }
function BeginFileDrag(Source: TWinControl; const Items: TDragItems;
  ExportFileURLs: Boolean; OnEnded: TDragEndedEvent): Boolean;

{ Lets List (a TListBox) drag its rows: RowItem gives a row's file (False
  for rows that cannot be dragged); OnBegan reports the dragged rows. }
procedure EnableListRowDrag(List: TWinControl; RowItem: TRowDragItemFunc;
  OnBegan: TRowsDragBeganEvent; OnEnded: TDragEndedEvent);

{ Zone accepts this app's drags: OnUpdate (enter and move) returns whether
  the point is a target, OnExit ends targeting, OnDrop performs it. }
procedure RegisterDropZone(Zone: TWinControl; OnUpdate: TDropZoneEvent;
  OnExit: TDropExitEvent; OnDrop: TDropZoneEvent);

{ True while a drag started by this app is in flight. }
function FileDragActive: Boolean;

{ Automation: reports whether List and Zone are wired for drags and saves
  Sample's drag label to PngPath. }
function FileDragSelfTest(List, Zone: TWinControl; const Sample: TDragItem;
  const PngPath: string): string;

implementation

{$IFDEF DARWIN}
uses
  CocoaAll, MacOSAll, LCLIntf, Formatters;

const
  CollectedFileType = 'software.ikari.opendisk.collected-file';
  MaxPreviewImages = 12;

type
  TClassPtr = Pointer;

function object_getClass(Obj: id): TClassPtr; cdecl; external 'objc' name 'object_getClass';
function class_getInstanceMethod(Cls: TClassPtr; Name: SEL): Pointer; cdecl;
  external 'objc' name 'class_getInstanceMethod';
function method_getImplementation(M: Pointer): Pointer; cdecl;
  external 'objc' name 'method_getImplementation';
function method_getTypeEncoding(M: Pointer): PChar; cdecl;
  external 'objc' name 'method_getTypeEncoding';
function class_addMethod(Cls: TClassPtr; Name: SEL; Imp: Pointer;
  Types: PChar): Boolean; cdecl; external 'objc' name 'class_addMethod';

type
  { macOS 10.11 API missing from the FPC 3.2.2 headers. }
  TMsgFontSizeWeight = function(Cls: id; Op: SEL; Size, Weight: CGFloat): id; cdecl;

const
  { NSFontWeightRegular. }
  FontWeightRegular = 0.0;

type
  { FileDragSource for views LCL draws itself. }
  TODDragSource = objcclass(NSObject, NSDraggingSourceProtocol)
  public
    function draggingSession_sourceOperationMaskForDraggingContext(
      session: NSDraggingSession; context: NSDraggingContext): NSDragOperation;
      message 'draggingSession:sourceOperationMaskForDraggingContext:';
    procedure draggingSession_endedAtPoint_operation(session: NSDraggingSession;
      screenPoint: NSPoint; operation: NSDragOperation);
      message 'draggingSession:endedAtPoint:operation:';
  end;

  { Table data source drag methods, copied onto the list's table class
    (self is then the table view). }
  TODTableDragMethods = objcclass(NSObject)
  public
    function tableView_pasteboardWriterForRow(tableView: NSTableView;
      row: NSInteger): id; message 'tableView:pasteboardWriterForRow:';
    procedure tableView_draggingSession_willBeginAtPoint_forRowIndexes(
      tableView: NSTableView; session: NSDraggingSession; screenPoint: NSPoint;
      rowIndexes: NSIndexSet);
      message 'tableView:draggingSession:willBeginAtPoint:forRowIndexes:';
    procedure tableView_draggingSession_endedAtPoint_operation(
      tableView: NSTableView; session: NSDraggingSession; screenPoint: NSPoint;
      operation: NSDragOperation);
      message 'tableView:draggingSession:endedAtPoint:operation:';
  end;

  { NSDraggingDestination methods, copied onto the drop zone's view class
    (self is then the zone's view). }
  TODDropMethods = objcclass(NSObject)
  public
    function odDraggingEntered(sender: NSDraggingInfoProtocol): NSDragOperation;
      message 'draggingEntered:';
    function odDraggingUpdated(sender: NSDraggingInfoProtocol): NSDragOperation;
      message 'draggingUpdated:';
    procedure odDraggingExited(sender: NSDraggingInfoProtocol);
      message 'draggingExited:';
    function odPerformDragOperation(sender: NSDraggingInfoProtocol): ObjCBOOL;
      message 'performDragOperation:';
  end;

  TListDrag = class
    View: Pointer;
    RowItem: TRowDragItemFunc;
    OnBegan: TRowsDragBeganEvent;
    OnEnded: TDragEndedEvent;
  end;

  TDropZone = class
    View: Pointer;
    OnUpdate: TDropZoneEvent;
    OnExit: TDropExitEvent;
    OnDrop: TDropZoneEvent;
  end;

var
  DragSource: TODDragSource = nil;
  SourceEnded: TDragEndedEvent = nil;
  DragActive: Boolean = False;
  ListDrags: TFPList = nil;
  DropZones: TFPList = nil;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

{ LCL screen coordinates from a Cocoa screen point (bottom-left origin of
  the primary screen). }
function ToLCLScreen(P: NSPoint): TPoint;
var
  Primary: NSScreen;
begin
  Primary := NSScreen(NSScreen.screens.objectAtIndex(0));
  Result := Types.Point(Round(P.x), Round(Primary.frame.size.height - P.y));
end;

{ The outermost view of a control: its handle. }
function HandleView(Control: TWinControl): NSView;
begin
  Result := NSView(Pointer(Control.Handle));
end;

{ The table inside a list box handle (a scroll view around it). }
function TableOf(Control: TWinControl): NSTableView;
var
  V: NSView;
begin
  Result := nil;
  V := HandleView(Control);
  if V.isKindOfClass(NSScrollView) then
    V := NSScrollView(V).documentView;
  if V.isKindOfClass(NSTableView) then
    Result := NSTableView(V);
end;

function CopyMethods(Helper: Pobjc_class; Target: TClassPtr;
  const Selectors: array of string): Boolean;
var
  I: Integer;
  M: Pointer;
begin
  Result := True;
  for I := 0 to High(Selectors) do
  begin
    M := class_getInstanceMethod(Helper, sel_registerName(PChar(Selectors[I])));
    if M = nil then
      Exit(False);
    { False when the class already has it: ours is in place already. }
    class_addMethod(Target, sel_registerName(PChar(Selectors[I])),
      method_getImplementation(M), method_getTypeEncoding(M));
  end;
end;

{ FileDragItem: the file URL when exported (and a real path), otherwise
  the in-app type only. }
function PasteboardWriter(const Item: TDragItem; ExportFileURL: Boolean): id;
var
  P: NSPasteboardItem;
begin
  if ExportFileURL and (Copy(Item.Path, 1, 2) <> '::') then
    Exit(NSURL.fileURLWithPath(NSStr(Item.Path)));
  P := NSPasteboardItem.alloc.init.autorelease;
  P.setString_forType(NSStr(Item.Path), NSStr(CollectedFileType));
  Result := P;
end;

{ FileDragLabel: icon, name and size on the window background, at most
  320 points wide. }
function LabelImage(const Item: TDragItem): NSImage;
const
  PadH = 8;
  PadV = 5;
  Gap = 6;
  IconSize = 16;
  MaxWidth = 320;
var
  NameAttrs, SizeAttrs: NSMutableDictionary;
  NameStr, SizeStr: NSString;
  NameSize, SizeSize, ImgSize: NSSize;
  Icon: NSImage;
  W, H, NameW: CGFloat;
  Para: NSMutableParagraphStyle;
begin
  NameAttrs := NSMutableDictionary.dictionary;
  NameAttrs.setObject_forKey(NSFont.systemFontOfSize(NSFont.systemFontSize), NSFontAttributeName);
  NameAttrs.setObject_forKey(NSColor.labelColor, NSForegroundColorAttributeName);
  Para := NSMutableParagraphStyle.alloc.init.autorelease;
  Para.setLineBreakMode(NSLineBreakByTruncatingMiddle);
  NameAttrs.setObject_forKey(Para, NSParagraphStyleAttributeName);
  SizeAttrs := NSMutableDictionary.dictionary;
  SizeAttrs.setObject_forKey(NSFont(TMsgFontSizeWeight(@objc_msgSend)(NSFont.classClass,
    sel_registerName('monospacedDigitSystemFontOfSize:weight:'),
    NSFont.systemFontSize, FontWeightRegular)), NSFontAttributeName);
  SizeAttrs.setObject_forKey(NSColor.secondaryLabelColor, NSForegroundColorAttributeName);

  NameStr := NSStr(Item.Name);
  SizeStr := NSStr(FormatFileSize(Item.Size));
  NameSize := NameStr.sizeWithAttributes(NameAttrs);
  SizeSize := SizeStr.sizeWithAttributes(SizeAttrs);

  if Copy(Item.Path, 1, 2) = '::' then
    Icon := NSWorkspace.sharedWorkspace.iconForFile(NSStr('/System'))
  else
    Icon := NSWorkspace.sharedWorkspace.iconForFile(NSStr(Item.Path));

  NameW := NameSize.width;
  W := PadH + IconSize + Gap + NameW + Gap + SizeSize.width + PadH;
  if W > MaxWidth then
  begin
    NameW := NameW - (W - MaxWidth);
    W := MaxWidth;
  end;
  H := NameSize.height;
  if H < IconSize then
    H := IconSize;
  H := PadV + H + PadV;
  ImgSize.width := Round(W);
  ImgSize.height := Round(H);

  Result := NSImage.alloc.initWithSize(ImgSize).autorelease;
  Result.lockFocus;
  try
    NSColor.windowBackgroundColor.colorWithAlphaComponent(0.92).setFill;
    NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
      NSMakeRect(0, 0, ImgSize.width, ImgSize.height), 6, 6).fill;
    if Icon <> nil then
      Icon.drawInRect_fromRect_operation_fraction(
        NSMakeRect(PadH, (ImgSize.height - IconSize) / 2, IconSize, IconSize),
        NSZeroRect, NSCompositeSourceOver, 1.0);
    NameStr.drawInRect_withAttributes(
      NSMakeRect(PadH + IconSize + Gap, (ImgSize.height - NameSize.height) / 2,
        NameW, NameSize.height), NameAttrs);
    SizeStr.drawAtPoint_withAttributes(
      NSMakePoint(ImgSize.width - PadH - SizeSize.width,
        (ImgSize.height - SizeSize.height) / 2), SizeAttrs);
  finally
    Result.unlockFocus;
  end;
end;

procedure EndDrag(ScreenPoint: NSPoint; Operation: NSDragOperation;
  Handler: TDragEndedEvent);
begin
  DragActive := False;
  { The session took the mouse-up; LCL never saw it. }
  ReleaseCapture;
  if Assigned(Handler) then
    Handler(ToLCLScreen(ScreenPoint), Operation <> NSDragOperationNone);
end;

{ FileDragSource.operationMask: copy within the app, copy or move outside. }
function OperationMask(Context: NSDraggingContext): NSDragOperation;
begin
  if Context = NSDraggingContextWithinApplication then
    Result := NSDragOperationCopy or NSDragOperationGeneric
  else
    Result := NSDragOperationCopy or NSDragOperationMove or NSDragOperationGeneric;
end;

function TODDragSource.draggingSession_sourceOperationMaskForDraggingContext(
  session: NSDraggingSession; context: NSDraggingContext): NSDragOperation;
begin
  Result := OperationMask(context);
end;

procedure TODDragSource.draggingSession_endedAtPoint_operation(
  session: NSDraggingSession; screenPoint: NSPoint; operation: NSDragOperation);
var
  Handler: TDragEndedEvent;
begin
  Handler := SourceEnded;
  SourceEnded := nil;
  EndDrag(screenPoint, operation, Handler);
end;

function FindListDrag(View: Pointer): TListDrag;
var
  I: Integer;
begin
  Result := nil;
  if ListDrags <> nil then
    for I := 0 to ListDrags.Count - 1 do
      if TListDrag(ListDrags[I]).View = View then
        Exit(TListDrag(ListDrags[I]));
end;

function TODTableDragMethods.tableView_pasteboardWriterForRow(
  tableView: NSTableView; row: NSInteger): id;
var
  D: TListDrag;
  Item: TDragItem;
begin
  Result := nil;
  D := FindListDrag(tableView);
  if (D = nil) or not D.RowItem(row, Item) then
    Exit;
  Result := PasteboardWriter(Item, True);
end;

procedure TODTableDragMethods.tableView_draggingSession_willBeginAtPoint_forRowIndexes(
  tableView: NSTableView; session: NSDraggingSession; screenPoint: NSPoint;
  rowIndexes: NSIndexSet);
var
  D: TListDrag;
  Rows: array of Integer;
  I: NSUInteger;
begin
  D := FindListDrag(tableView);
  if D = nil then
    Exit;
  DragActive := True;
  Rows := nil;
  I := rowIndexes.firstIndex;
  while I <> NSNotFound do
  begin
    SetLength(Rows, Length(Rows) + 1);
    Rows[High(Rows)] := I;
    I := rowIndexes.indexGreaterThanIndex(I);
  end;
  if Assigned(D.OnBegan) then
    D.OnBegan(Rows);
end;

procedure TODTableDragMethods.tableView_draggingSession_endedAtPoint_operation(
  tableView: NSTableView; session: NSDraggingSession; screenPoint: NSPoint;
  operation: NSDragOperation);
var
  D: TListDrag;
begin
  D := FindListDrag(tableView);
  if D <> nil then
    EndDrag(screenPoint, operation, D.OnEnded)
  else
    DragActive := False;
end;

function FindDropZone(View: Pointer): TDropZone;
var
  I: Integer;
begin
  Result := nil;
  if DropZones <> nil then
    for I := 0 to DropZones.Count - 1 do
      if TDropZone(DropZones[I]).View = View then
        Exit(TDropZone(DropZones[I]));
end;

function DraggingScreenPoint(View: NSView; Info: NSDraggingInfoProtocol): TPoint;
var
  R: NSRect;
begin
  R.origin := Info.draggingLocation;
  R.size.width := 0;
  R.size.height := 0;
  R := View.window.convertRectToScreen(R);
  Result := ToLCLScreen(R.origin);
end;

{ InAppFileDropDelegate.validateDrop / dropUpdated: only this app's drags,
  proposing a copy. }
function ZoneUpdate(View: NSView; Info: NSDraggingInfoProtocol): NSDragOperation;
var
  Z: TDropZone;
begin
  Result := NSDragOperationNone;
  Z := FindDropZone(View);
  if (Z = nil) or not DragActive then
    Exit;
  if Z.OnUpdate(DraggingScreenPoint(View, Info)) then
    Result := NSDragOperationCopy
  else if Assigned(Z.OnExit) then
    Z.OnExit();
end;

function TODDropMethods.odDraggingEntered(sender: NSDraggingInfoProtocol): NSDragOperation;
begin
  Result := ZoneUpdate(NSView(Pointer(Self)), sender);
end;

function TODDropMethods.odDraggingUpdated(sender: NSDraggingInfoProtocol): NSDragOperation;
begin
  Result := ZoneUpdate(NSView(Pointer(Self)), sender);
end;

procedure TODDropMethods.odDraggingExited(sender: NSDraggingInfoProtocol);
var
  Z: TDropZone;
begin
  Z := FindDropZone(Pointer(Self));
  if (Z <> nil) and Assigned(Z.OnExit) then
    Z.OnExit();
end;

function TODDropMethods.odPerformDragOperation(sender: NSDraggingInfoProtocol): ObjCBOOL;
var
  Z: TDropZone;
begin
  Result := False;
  Z := FindDropZone(Pointer(Self));
  if (Z = nil) or not DragActive then
    Exit;
  if Assigned(Z.OnExit) then
    Z.OnExit();
  Result := Z.OnDrop(DraggingScreenPoint(NSView(Pointer(Self)), sender));
end;

function BeginFileDrag(Source: TWinControl; const Items: TDragItems;
  ExportFileURLs: Boolean; OnEnded: TDragEndedEvent): Boolean;
var
  Event: NSEvent;
  View: NSView;
  DragItems: NSMutableArray;
  DI: NSDraggingItem;
  Image: NSImage;
  Cursor: NSPoint;
  Frame: NSRect;
  I: Integer;
  Offset: CGFloat;
  Session: NSDraggingSession;
begin
  Result := False;
  if (Length(Items) = 0) or not Source.HandleAllocated then
    Exit;
  Event := NSApp.currentEvent;
  if (Event = nil) or not ((Event.type_ = NSLeftMouseDragged) or
    (Event.type_ = NSLeftMouseDown)) then
    Exit;
  View := HandleView(Source);
  if View.window <> Event.window then
    Exit;
  if DragSource = nil then
    DragSource := TODDragSource.alloc.init;
  Cursor := View.convertPoint_fromView(Event.locationInWindow, nil);
  DragItems := NSMutableArray.array_;
  for I := 0 to High(Items) do
  begin
    DI := NSDraggingItem.alloc.initWithPasteboardWriter(
      PasteboardWriter(Items[I], ExportFileURLs)).autorelease;
    if I < MaxPreviewImages then
      Image := LabelImage(Items[I])
    else
      Image := nil;
    if I < MaxPreviewImages then
      Offset := I * 3
    else
      Offset := MaxPreviewImages * 3;
    if Image <> nil then
      Frame.size := Image.size
    else
    begin
      Frame.size.width := 32;
      Frame.size.height := 32;
    end;
    Frame.origin.x := Cursor.x - 14 + Offset;
    if View.isFlipped then
      Frame.origin.y := Cursor.y - Frame.size.height / 2 + Offset
    else
      Frame.origin.y := Cursor.y - Frame.size.height / 2 - Offset;
    DI.setDraggingFrame_contents(Frame, Image);
    DragItems.addObject(DI);
  end;
  { A previous session's handler never fires twice. }
  SourceEnded := OnEnded;
  DragActive := True;
  Session := View.beginDraggingSessionWithItems_event_source(DragItems, Event, DragSource);
  Session.setAnimatesToStartingPositionsOnCancelOrFail(ExportFileURLs);
  Result := True;
end;

procedure EnableListRowDrag(List: TWinControl; RowItem: TRowDragItemFunc;
  OnBegan: TRowsDragBeganEvent; OnEnded: TDragEndedEvent);
var
  Table: NSTableView;
  D: TListDrag;
begin
  Table := TableOf(List);
  if Table = nil then
    Exit;
  if not CopyMethods(TODTableDragMethods.classClass, object_getClass(Table),
    ['tableView:pasteboardWriterForRow:',
     'tableView:draggingSession:willBeginAtPoint:forRowIndexes:',
     'tableView:draggingSession:endedAtPoint:operation:']) then
    Exit;
  Table.setDraggingSourceOperationMask_forLocal(
    OperationMask(NSDraggingContextWithinApplication), True);
  Table.setDraggingSourceOperationMask_forLocal(
    OperationMask(NSDraggingContextOutsideApplication), False);
  if ListDrags = nil then
    ListDrags := TFPList.Create;
  D := FindListDrag(Table);
  if D = nil then
  begin
    D := TListDrag.Create;
    D.View := Table;
    ListDrags.Add(D);
  end;
  D.RowItem := RowItem;
  D.OnBegan := OnBegan;
  D.OnEnded := OnEnded;
end;

procedure RegisterDropZone(Zone: TWinControl; OnUpdate: TDropZoneEvent;
  OnExit: TDropExitEvent; OnDrop: TDropZoneEvent);
var
  View: NSView;
  Z: TDropZone;
begin
  View := HandleView(Zone);
  if not CopyMethods(TODDropMethods.classClass, object_getClass(View),
    ['draggingEntered:', 'draggingUpdated:', 'draggingExited:',
     'performDragOperation:']) then
    Exit;
  View.registerForDraggedTypes(NSArray.arrayWithObjects(
    NSStr(CollectedFileType), NSStr('public.file-url'), nil));
  if DropZones = nil then
    DropZones := TFPList.Create;
  Z := FindDropZone(View);
  if Z = nil then
  begin
    Z := TDropZone.Create;
    Z.View := View;
    DropZones.Add(Z);
  end;
  Z.OnUpdate := OnUpdate;
  Z.OnExit := OnExit;
  Z.OnDrop := OnDrop;
end;

function FileDragActive: Boolean;
begin
  Result := DragActive;
end;

function FileDragSelfTest(List, Zone: TWinControl; const Sample: TDragItem;
  const PngPath: string): string;

  function Yes(B: Boolean): string;
  begin
    if B then Result := 'yes' else Result := 'NO';
  end;

var
  Table: NSTableView;
  View: NSView;
  Image: NSImage;
  Rep: NSBitmapImageRep;
  Data: NSData;
  Writer: id;
begin
  Table := TableOf(List);
  View := HandleView(Zone);
  Result := 'table: ' + Yes(Table <> nil);
  if Table <> nil then
    Result := Result +
      '; pasteboardWriterForRow: ' + Yes(Table.respondsToSelector(
        sel_registerName('tableView:pasteboardWriterForRow:'))) +
      '; willBegin: ' + Yes(Table.respondsToSelector(
        sel_registerName('tableView:draggingSession:willBeginAtPoint:forRowIndexes:'))) +
      '; ended: ' + Yes(Table.respondsToSelector(
        sel_registerName('tableView:draggingSession:endedAtPoint:operation:'))) +
      '; registered list: ' + Yes(FindListDrag(Table) <> nil);
  Result := Result +
    '; zone draggingEntered: ' + Yes(View.respondsToSelector(sel_registerName('draggingEntered:'))) +
    '; performDrag: ' + Yes(View.respondsToSelector(sel_registerName('performDragOperation:'))) +
    '; zone types: ' + IntToStr(View.registeredDraggedTypes.count) +
    '; registered zone: ' + Yes(FindDropZone(View) <> nil);
  Writer := PasteboardWriter(Sample, True);
  Result := Result + '; writer: ' + NSObject(Writer).className.UTF8String;
  Writer := PasteboardWriter(Sample, False);
  Result := Result + '/' + NSObject(Writer).className.UTF8String;
  Image := LabelImage(Sample);
  Rep := NSBitmapImageRep.alloc.initWithData(Image.TIFFRepresentation).autorelease;
  Data := Rep.representationUsingType_properties(NSPNGFileType, nil);
  Result := Result + '; label ' + IntToStr(Round(Image.size.width)) + 'x' +
    IntToStr(Round(Image.size.height)) + ' saved: ' +
    Yes(Data.writeToFile_atomically(NSStr(PngPath), True));
end;

{$ELSE}

function BeginFileDrag(Source: TWinControl; const Items: TDragItems;
  ExportFileURLs: Boolean; OnEnded: TDragEndedEvent): Boolean;
begin
  Result := False;
end;

procedure EnableListRowDrag(List: TWinControl; RowItem: TRowDragItemFunc;
  OnBegan: TRowsDragBeganEvent; OnEnded: TDragEndedEvent);
begin
end;

procedure RegisterDropZone(Zone: TWinControl; OnUpdate: TDropZoneEvent;
  OnExit: TDropExitEvent; OnDrop: TDropZoneEvent);
begin
end;

function FileDragActive: Boolean;
begin
  Result := False;
end;

function FileDragSelfTest(List, Zone: TWinControl; const Sample: TDragItem;
  const PngPath: string): string;
begin
  Result := 'not supported';
end;

{$ENDIF}

end.
