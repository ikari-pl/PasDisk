{ PlatformAlert — a native alert with a "Do not ask again" checkbox.

  macOS: NSAlert with showsSuppressionButton, as FullDiskAccess.swift
  promptIfNotGranted uses (the app icon is NSAlert's default icon),
  reached through the Objective-C runtime. Elsewhere: an LCL question
  dialog without the checkbox. }

unit PlatformAlert;

{$mode objfpc}{$H+}

interface

{ Shows Title / Message with the buttons (first = default). Returns the
  0-based index of the button pressed; Suppressed tells whether the
  suppression checkbox was ticked (always False off macOS). }
function ShowSuppressibleAlert(const Title, Message: string;
  const Buttons: array of string; out Suppressed: Boolean): Integer;

implementation

uses
  SysUtils
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
{$ELSE}
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

end.
