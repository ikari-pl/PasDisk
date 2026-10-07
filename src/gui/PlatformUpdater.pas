{ PlatformUpdater — Sparkle software updates.

  Port of App/SoftwareUpdater.swift: one SPUStandardUpdaterController,
  started with the app (it schedules Sparkle's own background checks and
  asks the user about automatic checks on the second launch), and "Check
  for Updates…" calling checkForUpdates on its updater, enabled while
  updater.canCheckForUpdates. The feed (SUFeedURL) and the EdDSA public
  key (SUPublicEDKey) are in Info.plist.

  Sparkle.framework is loaded at run time from the bundle's Frameworks
  folder, so the app also runs without it (the bare development binary,
  other platforms): Available is then False and the UI hides the
  command. }

unit PlatformUpdater;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

{ Loads Sparkle and starts the updater; safe to call more than once. }
procedure StartUpdater;
{ Sparkle is loaded and the updater exists. }
function UpdaterAvailable: Boolean;
{ updater.canCheckForUpdates (False without Sparkle). }
function CanCheckForUpdates: Boolean;
{ updater.checkForUpdates: Sparkle's own window shows the result. }
procedure CheckForUpdates;

implementation

{$IFDEF DARWIN}
uses
  SysUtils, CocoaAll;

type
  TMsgObj = function(Obj: id; Op: SEL): id; cdecl;
  TMsgBool = function(Obj: id; Op: SEL): ObjCBOOL; cdecl;
  TMsgInit = function(Obj: id; Op: SEL; Start: ObjCBOOL; UpdaterDelegate,
    UserDriverDelegate: id): id; cdecl;
  TMsgVoidObj = procedure(Obj: id; Op: SEL; Arg: id); cdecl;

var
  Controller: id = nil;
  Tried: Boolean = False;

function SparkleBundle: NSBundle;
var
  Path: NSString;
begin
  Result := nil;
  Path := NSBundle.mainBundle.privateFrameworksPath;
  if Path = nil then
    Exit;
  Path := Path.stringByAppendingPathComponent(NSSTR('Sparkle.framework'));
  if not NSFileManager.defaultManager.fileExistsAtPath(Path) then
    Exit;
  Result := NSBundle.bundleWithPath(Path);
end;

procedure StartUpdater;
var
  Bundle: NSBundle;
  Cls: id;
begin
  if Tried then
    Exit;
  Tried := True;
  Bundle := SparkleBundle;
  if (Bundle = nil) or not Bundle.load then
    Exit;
  Cls := id(NSClassFromString(NSSTR('SPUStandardUpdaterController')));
  if Cls = nil then
    Exit;
  Controller := TMsgObj(@objc_msgSend)(Cls, sel_registerName('alloc'));
  { initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil;
    owned for the life of the app. }
  Controller := TMsgInit(@objc_msgSend)(Controller,
    sel_registerName('initWithStartingUpdater:updaterDelegate:userDriverDelegate:'),
    True, nil, nil);
end;

function UpdaterAvailable: Boolean;
begin
  Result := Controller <> nil;
end;

function Updater: id;
begin
  Result := nil;
  if Controller <> nil then
    Result := TMsgObj(@objc_msgSend)(Controller, sel_registerName('updater'));
end;

function CanCheckForUpdates: Boolean;
var
  U: id;
begin
  U := Updater;
  Result := (U <> nil) and TMsgBool(@objc_msgSend)(U, sel_registerName('canCheckForUpdates'));
end;

procedure CheckForUpdates;
var
  U: id;
begin
  U := Updater;
  if U <> nil then
    TMsgVoidObj(@objc_msgSend)(U, sel_registerName('checkForUpdates'), nil);
end;

{$ELSE}

procedure StartUpdater;
begin
end;

function UpdaterAvailable: Boolean;
begin
  Result := False;
end;

function CanCheckForUpdates: Boolean;
begin
  Result := False;
end;

procedure CheckForUpdates;
begin
end;

{$ENDIF}

end.
