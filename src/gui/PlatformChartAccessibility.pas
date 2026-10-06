{ PlatformChartAccessibility — VoiceOver for a custom-drawn chart.

  RingsChartView .accessibilityLabel(chartAccessibilityLabel) and
  .accessibilityChildren { one element per first-ring segment }: the
  chart view reports a label and child elements, each with a label, a
  value, a frame (the segment's bounds in the view), a button role for
  folders, and a press action. The NSAccessibility methods are added to
  the view's class; views that never registered keep NSView's answers. }

unit PlatformChartAccessibility;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, Controls, Types;

type
  TChartAccessibleItem = record
    ItemLabel: string;
    Value: string;
    IsButton: Boolean;
    { In the view's client coordinates. }
    Bounds: TRect;
  end;

  TChartAccessiblePress = procedure(Index: Integer) of object;

{ Replaces View's accessibility description: its label and its children. }
procedure SetChartAccessibility(View: TWinControl; const ChartLabel: string;
  const Items: array of TChartAccessibleItem; OnPress: TChartAccessiblePress);

{ Automation: what the accessibility API reports for View, one line per
  element (asked through the same NSAccessibility methods VoiceOver uses). }
function DescribeAccessibility(View: TWinControl): string;

implementation

{$IFDEF DARWIN}
uses
  SysUtils, CocoaAll;

type
  TClassPtr = Pointer;

  { A first-ring segment; its press goes back to the chart. }
  TODChartElement = objcclass(NSAccessibilityElement)
  private
    FIndex: NSInteger;
    FHost: Pointer;
  public
    function accessibilityPerformPress: ObjCBOOL; override;
  end;

  { The view-side methods, copied onto the chart view's class. }
  TODChartAccessMethods = objcclass(NSObject)
  public
    function odIsAccessibilityElement: ObjCBOOL; message 'isAccessibilityElement';
    function odAccessibilityLabel: NSString; message 'accessibilityLabel';
    function odAccessibilityRole: NSString; message 'accessibilityRole';
    function odAccessibilityChildren: NSArray; message 'accessibilityChildren';
  end;

  TChartHost = class
    View: Pointer;
    ChartLabel: NSString;
    Children: NSArray;
    OnPress: TChartAccessiblePress;
  end;

  TBoolImp = function(Self: id; Op: SEL): ObjCBOOL; cdecl;
  TObjImp = function(Self: id; Op: SEL): id; cdecl;

function object_getClass(Obj: id): TClassPtr; cdecl; external 'objc' name 'object_getClass';
function class_getSuperclass(Cls: TClassPtr): TClassPtr; cdecl;
  external 'objc' name 'class_getSuperclass';
function class_getInstanceMethod(Cls: TClassPtr; Name: SEL): Pointer; cdecl;
  external 'objc' name 'class_getInstanceMethod';
function method_getImplementation(M: Pointer): Pointer; cdecl;
  external 'objc' name 'method_getImplementation';
function method_getTypeEncoding(M: Pointer): PChar; cdecl;
  external 'objc' name 'method_getTypeEncoding';
function class_addMethod(Cls: TClassPtr; Name: SEL; Imp: Pointer;
  Types: PChar): Boolean; cdecl; external 'objc' name 'class_addMethod';

var
  Hosts: TFPList = nil;
  PatchedClass: TClassPtr = nil;
  { The superclass answers, for views that did not register. }
  SuperIsElement: TBoolImp = nil;
  SuperLabel, SuperRole, SuperChildren: TObjImp;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function FindHost(View: Pointer): TChartHost;
var
  I: Integer;
begin
  Result := nil;
  if Hosts <> nil then
    for I := 0 to Hosts.Count - 1 do
      if TChartHost(Hosts[I]).View = View then
        Exit(TChartHost(Hosts[I]));
end;

function TODChartElement.accessibilityPerformPress: ObjCBOOL;
var
  Host: TChartHost;
begin
  Host := FindHost(FHost);
  Result := (Host <> nil) and Assigned(Host.OnPress);
  if Result then
    Host.OnPress(FIndex);
end;

function TODChartAccessMethods.odIsAccessibilityElement: ObjCBOOL;
begin
  if FindHost(Pointer(Self)) <> nil then
    Result := True
  else
    Result := SuperIsElement(Self, sel_registerName('isAccessibilityElement'));
end;

function TODChartAccessMethods.odAccessibilityLabel: NSString;
var
  Host: TChartHost;
begin
  Host := FindHost(Pointer(Self));
  if Host <> nil then
    Result := Host.ChartLabel
  else
    Result := NSString(SuperLabel(Self, sel_registerName('accessibilityLabel')));
end;

function TODChartAccessMethods.odAccessibilityRole: NSString;
begin
  if FindHost(Pointer(Self)) <> nil then
    Result := NSAccessibilityGroupRole
  else
    Result := NSString(SuperRole(Self, sel_registerName('accessibilityRole')));
end;

function TODChartAccessMethods.odAccessibilityChildren: NSArray;
var
  Host: TChartHost;
begin
  Host := FindHost(Pointer(Self));
  if Host <> nil then
    Result := Host.Children
  else
    Result := NSArray(SuperChildren(Self, sel_registerName('accessibilityChildren')));
end;

function Patch(View: NSView): Boolean;
const
  Selectors: array[0..3] of string = ('isAccessibilityElement',
    'accessibilityLabel', 'accessibilityRole', 'accessibilityChildren');
var
  Cls, Super: TClassPtr;
  I: Integer;
  Mine: Pointer;
begin
  Cls := object_getClass(View);
  if PatchedClass <> nil then
    Exit(PatchedClass = Cls);
  Super := class_getSuperclass(Cls);
  SuperIsElement := TBoolImp(method_getImplementation(
    class_getInstanceMethod(Super, sel_registerName('isAccessibilityElement'))));
  SuperLabel := TObjImp(method_getImplementation(
    class_getInstanceMethod(Super, sel_registerName('accessibilityLabel'))));
  SuperRole := TObjImp(method_getImplementation(
    class_getInstanceMethod(Super, sel_registerName('accessibilityRole'))));
  SuperChildren := TObjImp(method_getImplementation(
    class_getInstanceMethod(Super, sel_registerName('accessibilityChildren'))));
  if not (Assigned(SuperIsElement) and Assigned(SuperLabel) and
    Assigned(SuperRole) and Assigned(SuperChildren)) then
    Exit(False);
  for I := 0 to High(Selectors) do
  begin
    Mine := class_getInstanceMethod(TODChartAccessMethods.classClass,
      sel_registerName(PChar(Selectors[I])));
    { The class must not implement these itself (LCL's views do not). }
    if not class_addMethod(Cls, sel_registerName(PChar(Selectors[I])),
      method_getImplementation(Mine), method_getTypeEncoding(Mine)) then
      Exit(False);
  end;
  PatchedClass := Cls;
  Result := True;
end;

procedure SetChartAccessibility(View: TWinControl; const ChartLabel: string;
  const Items: array of TChartAccessibleItem; OnPress: TChartAccessiblePress);
var
  V: NSView;
  Host: TChartHost;
  Children: NSMutableArray;
  E: TODChartElement;
  I: Integer;
  R: NSRect;
begin
  if (View = nil) or not View.HandleAllocated then
    Exit;
  V := NSView(Pointer(View.Handle));
  if not Patch(V) then
    Exit;
  if Hosts = nil then
    Hosts := TFPList.Create;
  Host := FindHost(V);
  if Host = nil then
  begin
    Host := TChartHost.Create;
    Host.View := V;
    Hosts.Add(Host);
  end;
  Children := NSMutableArray.alloc.initWithCapacity(Length(Items));
  for I := 0 to High(Items) do
  begin
    E := TODChartElement.alloc.init;
    E.FIndex := I;
    E.FHost := V;
    E.setAccessibilityParent(V);
    if Items[I].IsButton then
      E.setAccessibilityRole(NSAccessibilityButtonRole)
    else
      E.setAccessibilityRole(NSAccessibilityStaticTextRole);
    E.setAccessibilityLabel(NSStr(Items[I].ItemLabel));
    E.setAccessibilityValue(NSStr(Items[I].Value));
    R.origin.x := Items[I].Bounds.Left;
    R.origin.y := Items[I].Bounds.Top;
    R.size.width := Items[I].Bounds.Right - Items[I].Bounds.Left;
    R.size.height := Items[I].Bounds.Bottom - Items[I].Bounds.Top;
    { The view is flipped like the LCL client area; AppKit converts the
      parent-space frame to the screen as the window moves. }
    if not V.isFlipped then
      R.origin.y := V.bounds.size.height - R.origin.y - R.size.height;
    E.setAccessibilityFrameInParentSpace(R);
    Children.addObject(E);
    E.release;
  end;
  if Host.ChartLabel <> nil then
    Host.ChartLabel.release;
  if Host.Children <> nil then
    Host.Children.release;
  Host.ChartLabel := NSStr(ChartLabel).retain;
  Host.Children := Children;
  Host.OnPress := OnPress;
  NSAccessibilityPostNotification(V, NSAccessibilityLayoutChangedNotification);
end;

function DescribeAccessibility(View: TWinControl): string;
var
  V: NSView;
  Kids: NSArray;
  E: NSAccessibilityElement;
  I: Integer;
  F: NSRect;

  function S(Str: NSString): string;
  begin
    if Str = nil then
      Result := '(nil)'
    else
      Result := Str.UTF8String;
  end;

begin
  Result := '';
  if (View = nil) or not View.HandleAllocated then
    Exit;
  V := NSView(Pointer(View.Handle));
  Result := 'view: element=' + BoolToStr(V.isAccessibilityElement, True) +
    ' role=' + S(V.accessibilityRole) + ' label="' + S(V.accessibilityLabel) + '"';
  Kids := V.accessibilityChildren;
  if Kids = nil then
    Exit;
  Result := Result + ' children=' + IntToStr(Kids.count);
  for I := 0 to Kids.count - 1 do
  begin
    E := NSAccessibilityElement(Kids.objectAtIndex(I));
    F := E.accessibilityFrame;
    Result := Result + LineEnding + Format('  [%d] role=%s label="%s" value="%s" frame=%.0f,%.0f %.0fx%.0f',
      [I, S(E.accessibilityRole), S(E.accessibilityLabel), S(NSString(E.accessibilityValue)),
       F.origin.x, F.origin.y, F.size.width, F.size.height]);
  end;
end;

{$ELSE}

function DescribeAccessibility(View: TWinControl): string;
begin
  Result := '';
end;

procedure SetChartAccessibility(View: TWinControl; const ChartLabel: string;
  const Items: array of TChartAccessibleItem; OnPress: TChartAccessiblePress);
begin
end;

{$ENDIF}

end.
