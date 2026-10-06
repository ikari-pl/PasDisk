{ PlatformQuickLook — the Quick Look panel over the app's window.

  DiskAnalysisView .quickLookPreview($quickLookURL, in: urls) and
  centerQuickLookPanel: QLPreviewPanel shows one of a list of files (the
  arrow keys move through the list), centred on the window and kept on
  its screen. The panel takes its data from the first responder chain
  that accepts control, so the form's window class gets the three
  QLPreviewPanelController methods. }

unit PlatformQuickLook;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$linkframework Quartz}
{$ENDIF}

interface

uses
  Classes, SysUtils, Forms;

{ Shows Paths[StartIndex] (the others reachable with the arrow keys) over
  Window; replaces the list when the panel is already open. }
procedure ShowQuickLook(Window: TCustomForm; const Paths: array of string;
  StartIndex: Integer);
procedure CloseQuickLook;
function QuickLookVisible: Boolean;

implementation

{$IFDEF DARWIN}
uses
  CocoaAll, MacOSAll;

type
  TClassPtr = Pointer;

  QLPreviewPanel = objcclass external (NSPanel)
  public
    class function sharedPreviewPanel: QLPreviewPanel; message 'sharedPreviewPanel';
    class function sharedPreviewPanelExists: ObjCBOOL; message 'sharedPreviewPanelExists';
    procedure setDataSource(source: id); message 'setDataSource:';
    function dataSource: id; message 'dataSource';
    procedure updateController; message 'updateController';
    procedure reloadData; message 'reloadData';
    procedure setCurrentPreviewItemIndex(index: NSInteger);
      message 'setCurrentPreviewItemIndex:';
  end;

  { QLPreviewPanelDataSource: the file URLs (NSURL is a QLPreviewItem). }
  TODPreviewSource = objcclass(NSObject)
  private
    FItems: NSArray;
  public
    function numberOfPreviewItemsInPreviewPanel(panel: QLPreviewPanel): NSInteger;
      message 'numberOfPreviewItemsInPreviewPanel:';
    function previewPanel_previewItemAtIndex(panel: QLPreviewPanel; index: NSInteger): id;
      message 'previewPanel:previewItemAtIndex:';
    procedure dealloc; override;
  end;

  { QLPreviewPanelController, copied onto the form's window class (self is
    then the window). }
  TODPreviewController = objcclass(NSObject)
  public
    function acceptsPreviewPanelControl(panel: QLPreviewPanel): ObjCBOOL;
      message 'acceptsPreviewPanelControl:';
    procedure beginPreviewPanelControl(panel: QLPreviewPanel);
      message 'beginPreviewPanelControl:';
    procedure endPreviewPanelControl(panel: QLPreviewPanel);
      message 'endPreviewPanelControl:';
  end;

function object_getClass(Obj: id): TClassPtr; cdecl; external 'objc' name 'object_getClass';
function class_getInstanceMethod(Cls: TClassPtr; Name: SEL): Pointer; cdecl;
  external 'objc' name 'class_getInstanceMethod';
function method_getImplementation(M: Pointer): Pointer; cdecl;
  external 'objc' name 'method_getImplementation';
function method_getTypeEncoding(M: Pointer): PChar; cdecl;
  external 'objc' name 'method_getTypeEncoding';
function class_addMethod(Cls: TClassPtr; Name: SEL; Imp: Pointer;
  Types: PChar): Boolean; cdecl; external 'objc' name 'class_addMethod';

var
  Source: TODPreviewSource = nil;

function TODPreviewSource.numberOfPreviewItemsInPreviewPanel(panel: QLPreviewPanel): NSInteger;
begin
  if FItems = nil then
    Result := 0
  else
    Result := FItems.count;
end;

function TODPreviewSource.previewPanel_previewItemAtIndex(panel: QLPreviewPanel;
  index: NSInteger): id;
begin
  if (FItems = nil) or (index < 0) or (index >= NSInteger(FItems.count)) then
    Result := nil
  else
    Result := FItems.objectAtIndex(index);
end;

procedure TODPreviewSource.dealloc;
begin
  if FItems <> nil then
    FItems.release;
  inherited dealloc;
end;

function TODPreviewController.acceptsPreviewPanelControl(panel: QLPreviewPanel): ObjCBOOL;
begin
  Result := (Source <> nil) and (Source.FItems <> nil);
end;

procedure TODPreviewController.beginPreviewPanelControl(panel: QLPreviewPanel);
begin
  panel.setDataSource(Source);
end;

procedure TODPreviewController.endPreviewPanelControl(panel: QLPreviewPanel);
begin
  panel.setDataSource(nil);
end;

procedure InstallController(Window: NSWindow);
const
  Selectors: array[0..2] of string = ('acceptsPreviewPanelControl:',
    'beginPreviewPanelControl:', 'endPreviewPanelControl:');
var
  I: Integer;
  M: Pointer;
begin
  for I := 0 to High(Selectors) do
  begin
    M := class_getInstanceMethod(TODPreviewController.classClass,
      sel_registerName(PChar(Selectors[I])));
    if M <> nil then
      { False when the class already has it from an earlier call. }
      class_addMethod(object_getClass(Window), sel_registerName(PChar(Selectors[I])),
        method_getImplementation(M), method_getTypeEncoding(M));
  end;
end;

function WindowOf(Form: TCustomForm): NSWindow;
var
  View: NSView;
begin
  Result := nil;
  if (Form = nil) or not Form.HandleAllocated then
    Exit;
  View := NSView(Pointer(Form.Handle));
  Result := View.window;
end;

{ centerQuickLookPanel: on the window's centre, inside its screen. }
procedure CenterPanel(Panel: QLPreviewPanel; Window: NSWindow);
var
  F, W, S: NSRect;
  Screen: NSScreen;
begin
  F := Panel.frame;
  W := Window.frame;
  F.origin.x := W.origin.x + W.size.width / 2 - F.size.width / 2;
  F.origin.y := W.origin.y + W.size.height / 2 - F.size.height / 2;
  Screen := Window.screen;
  if Screen = nil then
    Screen := NSScreen.mainScreen;
  if Screen <> nil then
  begin
    S := Screen.visibleFrame;
    if F.origin.x > S.origin.x + S.size.width - F.size.width then
      F.origin.x := S.origin.x + S.size.width - F.size.width;
    if F.origin.x < S.origin.x then
      F.origin.x := S.origin.x;
    if F.origin.y > S.origin.y + S.size.height - F.size.height then
      F.origin.y := S.origin.y + S.size.height - F.size.height;
    if F.origin.y < S.origin.y then
      F.origin.y := S.origin.y;
  end;
  Panel.setFrame_display(F, True);
end;

procedure ShowQuickLook(Window: TCustomForm; const Paths: array of string;
  StartIndex: Integer);
var
  Win: NSWindow;
  Urls: NSMutableArray;
  Panel: QLPreviewPanel;
  I: Integer;
begin
  Win := WindowOf(Window);
  if (Win = nil) or (Length(Paths) = 0) then
    Exit;
  Urls := NSMutableArray.alloc.initWithCapacity(Length(Paths));
  for I := 0 to High(Paths) do
    Urls.addObject(NSURL.fileURLWithPath(NSString.stringWithUTF8String(PChar(Paths[I]))));
  if Source = nil then
    Source := TODPreviewSource.alloc.init;
  if Source.FItems <> nil then
    Source.FItems.release;
  Source.FItems := Urls;
  InstallController(Win);
  if StartIndex < 0 then
    StartIndex := 0;
  if StartIndex > High(Paths) then
    StartIndex := High(Paths);
  Panel := QLPreviewPanel.sharedPreviewPanel;
  if Panel.isVisible then
  begin
    Panel.reloadData;
    Panel.setCurrentPreviewItemIndex(StartIndex);
  end
  else
  begin
    Panel.makeKeyAndOrderFront(nil);
    { The panel looks for a controller along the responder chain; when the
      LCL window was not found there, give it the data directly. }
    Panel.updateController;
    if Panel.dataSource = nil then
    begin
      Panel.setDataSource(Source);
      Panel.reloadData;
    end;
    Panel.setCurrentPreviewItemIndex(StartIndex);
    CenterPanel(Panel, Win);
  end;
end;

procedure CloseQuickLook;
begin
  if QLPreviewPanel.sharedPreviewPanelExists then
    QLPreviewPanel.sharedPreviewPanel.orderOut(nil);
end;

function QuickLookVisible: Boolean;
begin
  Result := QLPreviewPanel.sharedPreviewPanelExists and
    QLPreviewPanel.sharedPreviewPanel.isVisible;
end;

{$ELSE}

procedure ShowQuickLook(Window: TCustomForm; const Paths: array of string;
  StartIndex: Integer);
begin
end;

procedure CloseQuickLook;
begin
end;

function QuickLookVisible: Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
