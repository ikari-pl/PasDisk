{ PlatformToolbar — the analysis window's native toolbar.

  DiskAnalysisView .toolbar / .searchable(placement: .toolbar) /
  .navigationTitle / .navigationSubtitle: a unified title bar holding
  Unmount (eject, before the title), the window title with the total size
  as its subtitle, the search field and Refresh (arrow.clockwise). The
  toolbar is shown only while analysing. }

unit PlatformToolbar;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, SysUtils, Forms;

type
  TToolbarSearchEvent = procedure(const Text: string) of object;

  TToolbarHandlers = record
    OnUnmount: TNotifyEvent;
    OnRefresh: TNotifyEvent;
    OnSearch: TToolbarSearchEvent;
  end;

{ Creates the toolbar on Form's window (once); it starts hidden. }
procedure InstallWindowToolbar(Form: TCustomForm; const Handlers: TToolbarHandlers);
procedure ShowWindowToolbar(Form: TCustomForm; Visible: Boolean);
{ navigationSubtitle; '' removes it. }
procedure SetWindowSubtitle(Form: TCustomForm; const Subtitle: string);
procedure SetToolbarSearchText(const Text: string);
function ToolbarSearchText: string;
procedure FocusToolbarSearch(Form: TCustomForm);
function ToolbarSearchFocused(Form: TCustomForm): Boolean;
{ False when the platform has no native toolbar (callers keep their own
  controls). }
function NativeToolbarAvailable: Boolean;

implementation

{$IFDEF DARWIN}
uses
  CocoaAll, MacOSAll;

const
  UnmountID = 'software.ikari.opendisk.unmount';
  SearchID = 'software.ikari.opendisk.search';
  RefreshID = 'software.ikari.opendisk.refresh';
  { NSWindowToolbarStyleUnified (macOS 11). }
  ToolbarStyleUnified = 3;

type
  TODToolbarDelegate = objcclass(NSObject, NSToolbarDelegateProtocol)
  public
    function toolbar_itemForItemIdentifier_willBeInsertedIntoToolbar(
      toolbar: NSToolbar; itemIdentifier: NSString; flag: ObjCBOOL): NSToolbarItem;
      message 'toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:';
    function toolbarDefaultItemIdentifiers(toolbar: NSToolbar): NSArray;
      message 'toolbarDefaultItemIdentifiers:';
    function toolbarAllowedItemIdentifiers(toolbar: NSToolbar): NSArray;
      message 'toolbarAllowedItemIdentifiers:';
    procedure unmountClicked(sender: id); message 'odUnmountClicked:';
    procedure refreshClicked(sender: id); message 'odRefreshClicked:';
    procedure searchChanged(sender: id); message 'odSearchChanged:';
  end;

  { macOS 11 API missing from the FPC 3.2.2 headers, sent by name. }
  TMsgVoidObj = procedure(Obj: id; Op: SEL; Arg: id); cdecl;
  TMsgVoidInt = procedure(Obj: id; Op: SEL; Arg: NSInteger); cdecl;
  TMsgVoidBool = procedure(Obj: id; Op: SEL; Arg: ObjCBOOL); cdecl;
  TMsgObjObj = function(Obj: id; Op: SEL; Arg: id): id; cdecl;
  TMsgObjObjObj = function(Obj: id; Op: SEL; A, B: id): id; cdecl;
  TMsgObj = function(Obj: id; Op: SEL): id; cdecl;

var
  Delegate: TODToolbarDelegate = nil;
  Handlers: TToolbarHandlers;
  SearchField: NSSearchField = nil;
  Updating: Boolean = False;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function Responds(Obj: id; const Name: string): Boolean;
begin
  Result := (Obj <> nil) and NSObject(Obj).respondsToSelector(sel_registerName(PChar(Name)));
end;

function SymbolImage(const Name, Description: string): NSImage;
var
  Cls: id;
begin
  Result := nil;
  Cls := id(NSImage.classClass);
  if Responds(Cls, 'imageWithSystemSymbolName:accessibilityDescription:') then
    Result := NSImage(TMsgObjObjObj(@objc_msgSend)(Cls,
      sel_registerName('imageWithSystemSymbolName:accessibilityDescription:'),
      NSStr(Name), NSStr(Description)));
end;

function ButtonItem(const Ident, Title, Symbol, Tip: string; Action: SEL): NSToolbarItem;
begin
  Result := NSToolbarItem.alloc.initWithItemIdentifier(NSStr(Ident)).autorelease;
  Result.setLabel(NSStr(Title));
  Result.setPaletteLabel(NSStr(Title));
  Result.setToolTip(NSStr(Tip));
  Result.setImage(SymbolImage(Symbol, Title));
  Result.setTarget(Delegate);
  Result.setAction(Action);
  if Responds(Result, 'setBordered:') then
    TMsgVoidBool(@objc_msgSend)(Result, sel_registerName('setBordered:'), True);
end;

function TODToolbarDelegate.toolbar_itemForItemIdentifier_willBeInsertedIntoToolbar(
  toolbar: NSToolbar; itemIdentifier: NSString; flag: ObjCBOOL): NSToolbarItem;
var
  Ident: string;
  Cls: id;
begin
  Result := nil;
  Ident := itemIdentifier.UTF8String;
  if Ident = UnmountID then
  begin
    Result := ButtonItem(UnmountID, 'Unmount', 'eject', 'Unmount and clear scan data',
      sel_registerName('odUnmountClicked:'));
    { ToolbarItem(placement: .navigation): before the title. }
    if Responds(Result, 'setNavigational:') then
      TMsgVoidBool(@objc_msgSend)(Result, sel_registerName('setNavigational:'), True);
  end
  else if Ident = RefreshID then
    Result := ButtonItem(RefreshID, 'Refresh', 'arrow.clockwise', 'Rescan the current folder',
      sel_registerName('odRefreshClicked:'))
  else if Ident = SearchID then
  begin
    Cls := objc_getClass('NSSearchToolbarItem');
    if Cls <> nil then
    begin
      { .searchable(placement: .toolbar) }
      Result := NSToolbarItem(NSObject(TMsgObj(@objc_msgSend)(Cls, sel_registerName('alloc'))));
      Result := Result.initWithItemIdentifier(NSStr(SearchID)).autorelease;
      SearchField := NSSearchField(TMsgObj(@objc_msgSend)(Result, sel_registerName('searchField')));
    end
    else
    begin
      Result := NSToolbarItem.alloc.initWithItemIdentifier(NSStr(SearchID)).autorelease;
      SearchField := NSSearchField.alloc.initWithFrame(NSMakeRect(0, 0, 240, 24)).autorelease;
      Result.setView(SearchField);
    end;
    Result.setLabel(NSStr('Search'));
    SearchField.setPlaceholderString(NSStr('Search scanned files and folders'));
    SearchField.setTarget(Delegate);
    SearchField.setAction(sel_registerName('odSearchChanged:'));
    { Every keystroke reaches the search (SearchController debounces). }
    SearchField.setSendsSearchStringImmediately(True);
    SearchField.setSendsWholeSearchString(False);
  end;
end;

function TODToolbarDelegate.toolbarDefaultItemIdentifiers(toolbar: NSToolbar): NSArray;
begin
  Result := NSArray.arrayWithObjects(NSStr(UnmountID), NSToolbarFlexibleSpaceItemIdentifier,
    NSStr(SearchID), NSStr(RefreshID), nil);
end;

function TODToolbarDelegate.toolbarAllowedItemIdentifiers(toolbar: NSToolbar): NSArray;
begin
  Result := toolbarDefaultItemIdentifiers(toolbar);
end;

procedure TODToolbarDelegate.unmountClicked(sender: id);
begin
  if Assigned(Handlers.OnUnmount) then
    Handlers.OnUnmount(nil);
end;

procedure TODToolbarDelegate.refreshClicked(sender: id);
begin
  if Assigned(Handlers.OnRefresh) then
    Handlers.OnRefresh(nil);
end;

procedure TODToolbarDelegate.searchChanged(sender: id);
begin
  if not Updating and Assigned(Handlers.OnSearch) then
    Handlers.OnSearch(ToolbarSearchText);
end;

function WindowOf(Form: TCustomForm): NSWindow;
begin
  Result := nil;
  if (Form <> nil) and Form.HandleAllocated then
    Result := NSView(Pointer(Form.Handle)).window;
end;

procedure InstallWindowToolbar(Form: TCustomForm; const Handlers: TToolbarHandlers);
var
  Win: NSWindow;
  Bar: NSToolbar;
begin
  PlatformToolbar.Handlers := Handlers;
  Win := WindowOf(Form);
  if (Win = nil) or (Win.toolbar <> nil) then
    Exit;
  if Delegate = nil then
    Delegate := TODToolbarDelegate.alloc.init;
  Bar := NSToolbar.alloc.initWithIdentifier(NSStr('software.ikari.opendisk.analysis')).autorelease;
  Bar.setDelegate(NSToolbarDelegateProtocol(Pointer(Delegate)));
  Bar.setDisplayMode(NSToolbarDisplayModeIconOnly);
  Bar.setAllowsUserCustomization(False);
  Bar.setVisible(False);
  Win.setToolbar(Bar);
  if Responds(Win, 'setToolbarStyle:') then
    TMsgVoidInt(@objc_msgSend)(Win, sel_registerName('setToolbarStyle:'), ToolbarStyleUnified);
  { LCL gives sizeable windows the bundle URL as their represented URL,
    which the unified title bar shows as a folder proxy icon; Swift's
    window has none. }
  Win.setRepresentedURL(nil);
end;

procedure ShowWindowToolbar(Form: TCustomForm; Visible: Boolean);
var
  Win: NSWindow;
begin
  Win := WindowOf(Form);
  if (Win <> nil) and (Win.toolbar <> nil) then
    Win.toolbar.setVisible(Visible);
end;

procedure SetWindowSubtitle(Form: TCustomForm; const Subtitle: string);
var
  Win: NSWindow;
begin
  Win := WindowOf(Form);
  if Responds(Win, 'setSubtitle:') then
    TMsgVoidObj(@objc_msgSend)(Win, sel_registerName('setSubtitle:'), NSStr(Subtitle));
end;

procedure SetToolbarSearchText(const Text: string);
begin
  if SearchField = nil then
    Exit;
  Updating := True;
  try
    SearchField.setStringValue(NSStr(Text));
  finally
    Updating := False;
  end;
end;

function ToolbarSearchText: string;
begin
  if SearchField = nil then
    Result := ''
  else
    Result := SearchField.stringValue.UTF8String;
end;

procedure FocusToolbarSearch(Form: TCustomForm);
var
  Win: NSWindow;
begin
  Win := WindowOf(Form);
  if (Win <> nil) and (SearchField <> nil) then
  begin
    Win.makeFirstResponder(SearchField);
    SearchField.selectText(nil);
  end;
end;

function ToolbarSearchFocused(Form: TCustomForm): Boolean;
var
  Win: NSWindow;
  Responder: NSResponder;
begin
  Result := False;
  Win := WindowOf(Form);
  if (Win = nil) or (SearchField = nil) then
    Exit;
  Responder := Win.firstResponder;
  { The field edits through the window's shared field editor. }
  Result := (Responder = NSResponder(SearchField)) or
    (Responder.isKindOfClass(NSTextView) and
     (NSTextView(Responder).delegate = NSTextViewDelegateProtocol(Pointer(SearchField))));
end;

function NativeToolbarAvailable: Boolean;
begin
  Result := True;
end;

{$ELSE}

procedure InstallWindowToolbar(Form: TCustomForm; const Handlers: TToolbarHandlers);
begin
end;

procedure ShowWindowToolbar(Form: TCustomForm; Visible: Boolean);
begin
end;

procedure SetWindowSubtitle(Form: TCustomForm; const Subtitle: string);
begin
end;

procedure SetToolbarSearchText(const Text: string);
begin
end;

function ToolbarSearchText: string;
begin
  Result := '';
end;

procedure FocusToolbarSearch(Form: TCustomForm);
begin
end;

function ToolbarSearchFocused(Form: TCustomForm): Boolean;
begin
  Result := False;
end;

function NativeToolbarAvailable: Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
