{ PlatformMotion — the display's frame clock and the Reduce Motion setting.

  TFrameClock calls OnFrame once per display refresh while running: a
  CADisplayLink from the view (NSView displayLinkWithTarget:selector:,
  macOS 14) that follows the screen the view is on, else a 16-ms timer.
  It runs only between Start and Stop, so idle windows keep no timer.
  ReduceMotion is NSWorkspace accessibilityDisplayShouldReduceMotion. }

unit PlatformMotion;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls;

type
  TFrameClock = class
  private
    FView: TWinControl;
    FOnFrame: TNotifyEvent;
    FRunning: Boolean;
    FTimer: TTimer;
    FLink: Pointer;
    FTarget: Pointer;
    procedure TimerTick(Sender: TObject);
  public
    constructor Create(View: TWinControl; OnFrame: TNotifyEvent);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    { Called by the display link. }
    procedure Frame;
    property Running: Boolean read FRunning;
    { True when frames come from the display link, not the fallback timer. }
    function DisplayLinked: Boolean;
  end;

{ System Settings > Accessibility > Display > Reduce motion. }
function ReduceMotion: Boolean;

{ The control's opacity (NSView alphaValue), 0..1, for fades. }
procedure SetControlAlpha(Control: TWinControl; Alpha: Double);

implementation

{$IFDEF DARWIN}
uses
  CocoaAll;

type
  TODFrameTarget = objcclass(NSObject)
  private
    FClock: TFrameClock;
  public
    procedure tick(link: id); message 'odFrameTick:';
  end;

  TMsgLink = function(Obj: id; Op: SEL; Target: id; Action: SEL): id; cdecl;
  TMsgRunLoop = procedure(Obj: id; Op: SEL; Loop: id; Mode: id); cdecl;
  TMsgVoid = procedure(Obj: id; Op: SEL); cdecl;
  TMsgBool = function(Obj: id; Op: SEL): ObjCBOOL; cdecl;

procedure TODFrameTarget.tick(link: id);
begin
  if FClock <> nil then
    FClock.Frame;
end;

function ReduceMotion: Boolean;
var
  W: id;
begin
  W := id(NSWorkspace.sharedWorkspace);
  Result := NSObject(W).respondsToSelector(sel_registerName('accessibilityDisplayShouldReduceMotion')) and
    TMsgBool(@objc_msgSend)(W, sel_registerName('accessibilityDisplayShouldReduceMotion'));
end;

procedure SetControlAlpha(Control: TWinControl; Alpha: Double);
begin
  if (Control <> nil) and Control.HandleAllocated then
    NSView(Pointer(Control.Handle)).setAlphaValue(Alpha);
end;

function CreateLink(Clock: TFrameClock; View: TWinControl; out Target: Pointer): Pointer;
var
  V: NSView;
  T: TODFrameTarget;
  Link: id;
begin
  Result := nil;
  Target := nil;
  if (View = nil) or not View.HandleAllocated then
    Exit;
  V := NSView(Pointer(View.Handle));
  if not V.respondsToSelector(sel_registerName('displayLinkWithTarget:selector:')) then
    Exit;
  T := TODFrameTarget.alloc.init;
  T.FClock := Clock;
  Link := TMsgLink(@objc_msgSend)(V, sel_registerName('displayLinkWithTarget:selector:'),
    T, sel_registerName('odFrameTick:'));
  if Link = nil then
  begin
    T.release;
    Exit;
  end;
  NSObject(Link).retain;
  { Common modes: frames keep coming during live resize and tracking. }
  TMsgRunLoop(@objc_msgSend)(Link, sel_registerName('addToRunLoop:forMode:'),
    NSRunLoop.mainRunLoop, NSRunLoopCommonModes);
  Target := T;
  Result := Link;
end;

procedure DestroyLink(var Link, Target: Pointer);
begin
  if Link <> nil then
  begin
    TMsgVoid(@objc_msgSend)(id(Link), sel_registerName('invalidate'));
    NSObject(Link).release;
    Link := nil;
  end;
  if Target <> nil then
  begin
    TODFrameTarget(Target).FClock := nil;
    TODFrameTarget(Target).release;
    Target := nil;
  end;
end;
{$ELSE}
function ReduceMotion: Boolean;
begin
  Result := False;
end;

procedure SetControlAlpha(Control: TWinControl; Alpha: Double);
begin
end;

function CreateLink(Clock: TFrameClock; View: TWinControl; out Target: Pointer): Pointer;
begin
  Target := nil;
  Result := nil;
end;

procedure DestroyLink(var Link, Target: Pointer);
begin
end;
{$ENDIF}

constructor TFrameClock.Create(View: TWinControl; OnFrame: TNotifyEvent);
begin
  inherited Create;
  FView := View;
  FOnFrame := OnFrame;
end;

destructor TFrameClock.Destroy;
begin
  Stop;
  FTimer.Free;
  inherited Destroy;
end;

procedure TFrameClock.Start;
begin
  if FRunning then
    Exit;
  FRunning := True;
  FLink := CreateLink(Self, FView, FTarget);
  if FLink = nil then
  begin
    if FTimer = nil then
    begin
      FTimer := TTimer.Create(nil);
      FTimer.Interval := 16;
      FTimer.OnTimer := @TimerTick;
    end;
    FTimer.Enabled := True;
  end;
end;

procedure TFrameClock.Stop;
begin
  if not FRunning then
    Exit;
  FRunning := False;
  DestroyLink(FLink, FTarget);
  if FTimer <> nil then
    FTimer.Enabled := False;
end;

procedure TFrameClock.Frame;
begin
  if FRunning and Assigned(FOnFrame) then
    FOnFrame(Self);
end;

function TFrameClock.DisplayLinked: Boolean;
begin
  Result := FLink <> nil;
end;

procedure TFrameClock.TimerTick(Sender: TObject);
begin
  Frame;
end;

end.
