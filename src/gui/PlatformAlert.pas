{ PlatformAlert — a native alert with a "Do not ask again" checkbox.

  macOS: NSAlert with showsSuppressionButton, as FullDiskAccess.swift
  promptIfNotGranted uses (the app icon is NSAlert's default icon),
  reached through the Objective-C runtime. Elsewhere: an LCL question
  dialog without the checkbox. }

unit PlatformAlert;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch cblocks}
{$ENDIF}

interface

uses
  Forms;

type
  TConfirmResult = procedure(Confirmed: Boolean) of object;

{ Shows Title / Message with the buttons (first = default). Returns the
  0-based index of the button pressed; Suppressed tells whether the
  suppression checkbox was ticked (always False off macOS). }
function ShowSuppressibleAlert(const Title, Message: string;
  const Buttons: array of string; out Suppressed: Boolean): Integer;

{ A confirmation like SwiftUI's confirmationDialog with a destructive
  button: Title / Message, ConfirmTitle (red, destructive) and Cancel
  (the default for Return/Escape safety). True when confirmed. }
function ConfirmDestructive(const Title, Message, ConfirmTitle: string): Boolean;

{ The same confirmation as a sheet on Window (confirmationDialog on
  macOS); OnResult gets the answer when the sheet closes — unless Window
  is destroyed first, then it is never called. One such sheet at a time:
  returns False (and shows nothing) while another is open; the sheet is
  window-modal, so the window cannot ask twice through its own UI.
  Without a native window it falls back to ConfirmDestructive and calls
  OnResult before returning. }
function ConfirmDestructiveSheet(Window: TCustomForm; const Title, Message,
  ConfirmTitle: string; OnResult: TConfirmResult): Boolean;

implementation

uses
  SysUtils, Classes
  {$IFDEF DARWIN}, MacOSAll{$ELSE}, Dialogs, Controls{$ENDIF};

{$IFDEF DARWIN}
procedure objc_msgSend; cdecl; external 'objc' name 'objc_msgSend';
function objc_getClass(Name: PAnsiChar): Pointer; cdecl; external 'objc';
function sel_registerName(Name: PAnsiChar): Pointer; cdecl; external 'objc';

type
  TMsgObj = function(Self, Op: Pointer): Pointer; cdecl;
  TMsgObjArg = function(Self, Op, Arg: Pointer): Pointer; cdecl;
  TMsgVoidBool = procedure(Self, Op: Pointer; Value: ByteBool); cdecl;
  TMsgInt = function(Self, Op: Pointer): PtrInt; cdecl;
  TMsgObjInt = function(Self, Op: Pointer; Value: PtrInt): Pointer; cdecl;

function Sel(const Name: string): Pointer;
begin
  Result := sel_registerName(PAnsiChar(Name));
end;

function ShowSuppressibleAlert(const Title, Message: string;
  const Buttons: array of string; out Suppressed: Boolean): Integer;
const
  NSAlertFirstButtonReturn = 1000;
  NSControlStateValueOn = 1;
var
  Alert, Str, Check: Pointer;
  I: Integer;
  Response: PtrInt;

  procedure SendString(const Selector, Value: string);
  begin
    Str := CFStringCreateWithCString(nil, PChar(Value), kCFStringEncodingUTF8);
    try
      TMsgObjArg(@objc_msgSend)(Alert, Sel(Selector), Str);
    finally
      CFRelease(Str);
    end;
  end;

begin
  Suppressed := False;
  Alert := TMsgObj(@objc_msgSend)(objc_getClass('NSAlert'), Sel('alloc'));
  Alert := TMsgObj(@objc_msgSend)(Alert, Sel('init'));
  if Alert = nil then
    Exit(-1);
  try
    SendString('setMessageText:', Title);
    SendString('setInformativeText:', Message);
    TMsgVoidBool(@objc_msgSend)(Alert, Sel('setShowsSuppressionButton:'), True);
    for I := 0 to High(Buttons) do
      SendString('addButtonWithTitle:', Buttons[I]);
    Response := TMsgInt(@objc_msgSend)(Alert, Sel('runModal'));
    Check := TMsgObj(@objc_msgSend)(Alert, Sel('suppressionButton'));
    if Check <> nil then
      Suppressed := TMsgInt(@objc_msgSend)(Check, Sel('state')) = NSControlStateValueOn;
    Result := Response - NSAlertFirstButtonReturn;
  finally
    TMsgObj(@objc_msgSend)(Alert, Sel('release'));
  end;
end;
const
  NSAlertFirstButtonReturn = 1000;

{ NSAlert, warning style: ConfirmTitle red and destructive (no Return key
  equivalent), then Cancel. The caller releases it. }
function BuildDestructiveAlert(const Title, Message, ConfirmTitle: string): Pointer;
const
  NSAlertStyleWarning = 0;
var
  Alert, Str, Button: Pointer;

  procedure SendString(Target: Pointer; const Selector, Value: string);
  begin
    Str := CFStringCreateWithCString(nil, PChar(Value), kCFStringEncodingUTF8);
    try
      TMsgObjArg(@objc_msgSend)(Target, Sel(Selector), Str);
    finally
      CFRelease(Str);
    end;
  end;

begin
  Alert := TMsgObj(@objc_msgSend)(objc_getClass('NSAlert'), Sel('alloc'));
  Alert := TMsgObj(@objc_msgSend)(Alert, Sel('init'));
  Result := Alert;
  if Alert = nil then
    Exit;
  SendString(Alert, 'setMessageText:', Title);
  SendString(Alert, 'setInformativeText:', Message);
  TMsgObjInt(@objc_msgSend)(Alert, Sel('setAlertStyle:'), NSAlertStyleWarning);
  SendString(Alert, 'addButtonWithTitle:', ConfirmTitle);
  Button := TMsgObj(@objc_msgSend)(Alert, Sel('buttons'));
  Button := TMsgObjInt(@objc_msgSend)(Button, Sel('objectAtIndex:'), 0);
  { Red, and not triggered by Return. }
  TMsgVoidBool(@objc_msgSend)(Button, Sel('setHasDestructiveAction:'), True);
  Str := CFStringCreateWithCString(nil, '', kCFStringEncodingUTF8);
  TMsgObjArg(@objc_msgSend)(Button, Sel('setKeyEquivalent:'), Str);
  CFRelease(Str);
  SendString(Alert, 'addButtonWithTitle:', 'Cancel');
end;

function ConfirmDestructive(const Title, Message, ConfirmTitle: string): Boolean;
var
  Alert: Pointer;
begin
  Result := False;
  Alert := BuildDestructiveAlert(Title, Message, ConfirmTitle);
  if Alert = nil then
    Exit;
  try
    Result := TMsgInt(@objc_msgSend)(Alert, Sel('runModal')) = NSAlertFirstButtonReturn;
  finally
    TMsgObj(@objc_msgSend)(Alert, Sel('release'));
  end;
end;

type
  TSheetResponse = reference to procedure(Response: PtrInt); cdecl; cblock;
  TMsgSheet = procedure(Self, Op, Window: Pointer; Handler: TSheetResponse); cdecl;

type
  { Watches the window the sheet belongs to: if it is destroyed while the
    sheet is open, the pending answer is dropped instead of being sent to
    a freed object. }
  TSheetOwnerWatch = class(TComponent)
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  end;

var
  { The open sheet. A plain block procedure carries no state, so there is
    one open sheet at a time and its context lives here. }
  SheetAlert: Pointer = nil;
  SheetResult: TConfirmResult = nil;
  SheetOwner: TComponent = nil;
  SheetWatch: TSheetOwnerWatch = nil;

procedure TSheetOwnerWatch.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = SheetOwner) then
  begin
    SheetOwner := nil;
    SheetResult := nil;
  end;
end;

procedure SheetEnded(Response: PtrInt);
var
  Done: TConfirmResult;
begin
  Done := SheetResult;
  SheetResult := nil;
  try
    if (SheetOwner <> nil) and (SheetWatch <> nil) then
      SheetOwner.RemoveFreeNotification(SheetWatch);
    SheetOwner := nil;
  finally
    if SheetAlert <> nil then
      TMsgObj(@objc_msgSend)(SheetAlert, Sel('release'));
    SheetAlert := nil;
  end;
  if Assigned(Done) then
    Done(Response = NSAlertFirstButtonReturn);
end;

function ConfirmDestructiveSheet(Window: TCustomForm; const Title, Message,
  ConfirmTitle: string; OnResult: TConfirmResult): Boolean;
var
  Win: Pointer;
begin
  Result := False;
  if SheetAlert <> nil then
    Exit;
  Win := nil;
  if (Window <> nil) and Window.HandleAllocated then
    Win := TMsgObj(@objc_msgSend)(Pointer(Window.Handle), Sel('window'));
  if Win = nil then
  begin
    OnResult(ConfirmDestructive(Title, Message, ConfirmTitle));
    Exit(True);
  end;
  SheetAlert := BuildDestructiveAlert(Title, Message, ConfirmTitle);
  if SheetAlert = nil then
    Exit;
  if SheetWatch = nil then
    SheetWatch := TSheetOwnerWatch.Create(nil);
  SheetOwner := Window;
  Window.FreeNotification(SheetWatch);
  SheetResult := OnResult;
  TMsgSheet(@objc_msgSend)(SheetAlert, Sel('beginSheetModalForWindow:completionHandler:'),
    Win, @SheetEnded);
  Result := True;
end;
{$ELSE}
function ConfirmDestructive(const Title, Message, ConfirmTitle: string): Boolean;
begin
  Result := QuestionDlg(Title, Message, mtWarning,
    [mrYes, ConfirmTitle, mrCancel, 'Cancel', 'IsDefault', 'IsCancel'], 0) = mrYes;
end;

function ConfirmDestructiveSheet(Window: TCustomForm; const Title, Message,
  ConfirmTitle: string; OnResult: TConfirmResult): Boolean;
begin
  OnResult(ConfirmDestructive(Title, Message, ConfirmTitle));
  Result := True;
end;

function ShowSuppressibleAlert(const Title, Message: string;
  const Buttons: array of string; out Suppressed: Boolean): Integer;
begin
  Suppressed := False;
  if Length(Buttons) >= 2 then
  begin
    if QuestionDlg(Title, Message, mtInformation,
      [mrYes, Buttons[0], mrNo, Buttons[1]], 0) = mrYes then
      Result := 0
    else
      Result := 1;
  end
  else
  begin
    MessageDlg(Title, Message, mtInformation, [mbOK], 0);
    Result := 0;
  end;
end;
{$ENDIF}

{$IFDEF DARWIN}
finalization
  FreeAndNil(SheetWatch);
{$ENDIF}

end.
