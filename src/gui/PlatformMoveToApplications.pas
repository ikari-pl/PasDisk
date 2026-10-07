{ PlatformMoveToApplications — offer to move the app into Applications.

  Port of App/MoveToApplications.swift. Run once at startup:
  - translocated (macOS ran the app from a randomized read-only copy
    because it is quarantined and was opened where it was downloaded):
    strip the quarantine flag from the original and relaunch from there,
    at most once in a row;
  - outside an Applications folder: ask "Move PasDisk to your Applications
    folder?" (Move to Applications / Not Now, "Don't ask again"); move it
    into /Applications, else ~/Applications, trashing a copy already there
    (copy + trash the original when a move fails), strip quarantine and
    relaunch from the new place after this process exits.
  Swift skips it in DEBUG builds and Xcode's DerivedData; here it is
  skipped for a bundle inside a source checkout (next to .git). True means
  the app is relaunching and should quit. }

unit PlatformMoveToApplications;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

function PromptMoveToApplicationsIfNeeded: Boolean;

implementation

{$IFDEF DARWIN}
uses
  SysUtils, Classes, Process, BaseUnix, DynLibs, CocoaAll, MacOSAll,
  PlatformPreferences;

const
  SuppressionKey = 'move_to_applications_suppressed';
  RelaunchAttemptKey = 'translocation_relaunch_attempted';
  AppName = 'PasDisk';

type
  TIsTranslocated = function(Url: CFURLRef; IsTranslocated: PBoolean;
    Error: Pointer): Boolean; cdecl;
  TOriginalPath = function(Url: CFURLRef; Error: Pointer): CFURLRef; cdecl;

function getxattr(Path, Name: PChar; Value: Pointer; Size: csize_t;
  Position: cuint32; Options: cint): ssize_t; cdecl; external 'c';

const
  XATTR_NOFOLLOW = 1;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function PathOfURL(Url: CFURLRef): string;
var
  Buf: array[0..4095] of Char;
begin
  Result := '';
  if (Url <> nil) and CFURLGetFileSystemRepresentation(Url, True, @Buf[0], SizeOf(Buf)) then
    Result := StrPas(@Buf[0]);
end;

{ The original location of a translocated bundle, or '' when it is not
  translocated (SecTranslocate* are looked up at run time, as in Swift). }
function TranslocationOriginal(const BundlePath: string): string;
var
  Lib: TLibHandle;
  IsTranslocated: TIsTranslocated;
  OriginalPath: TOriginalPath;
  Url, Original: CFURLRef;
  Translocated: Boolean;
begin
  Result := '';
  Lib := LoadLibrary('/System/Library/Frameworks/Security.framework/Security');
  if Lib = NilHandle then
    Exit;
  try
    Pointer(IsTranslocated) := GetProcAddress(Lib, 'SecTranslocateIsTranslocatedURL');
    Pointer(OriginalPath) := GetProcAddress(Lib, 'SecTranslocateCreateOriginalPathForURL');
    if not Assigned(IsTranslocated) or not Assigned(OriginalPath) then
      Exit;
    Url := CFURLCreateFromFileSystemRepresentation(nil, PChar(BundlePath),
      Length(BundlePath), True);
    if Url = nil then
      Exit;
    try
      Translocated := False;
      if not IsTranslocated(Url, @Translocated, nil) or not Translocated then
        Exit;
      Original := OriginalPath(Url, nil);
      if Original <> nil then
      begin
        Result := ExcludeTrailingPathDelimiter(PathOfURL(Original));
        CFRelease(Original);
      end;
    finally
      CFRelease(Url);
    end;
  finally
    UnloadLibrary(Lib);
  end;
end;

{ Swift: the parent path matches (^|/)Applications(/|$). }
function IsInApplicationsFolder(const BundlePath: string): Boolean;
var
  Parent: string;
begin
  Parent := '/' + ExcludeTrailingPathDelimiter(ExtractFileDir(BundlePath)) + '/';
  Result := Pos('/Applications/', Parent) > 0;
end;

{ A development build: the bundle sits in a source checkout. }
function IsDevelopmentBuild(const BundlePath: string): Boolean;
begin
  Result := DirectoryExists(IncludeTrailingPathDelimiter(ExtractFileDir(BundlePath)) + '.git') or
    FileExists(IncludeTrailingPathDelimiter(ExtractFileDir(BundlePath)) + '.git');
end;

function StripQuarantine(const Path: string): Boolean;
var
  Output: string;
begin
  RunCommand('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', Path], Output,
    [poNoConsole]);
  Result := getxattr(PChar(Path), 'com.apple.quarantine', nil, 0, 0, XATTR_NOFOLLOW) < 0;
end;

{ Reopens Path once this process has exited, then quits. }
procedure Relaunch(const Path: string);
var
  P: TProcess;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(Format(
      'while /bin/kill -0 %d 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open "$0"',
      [fpGetPid]));
    P.Parameters.Add(Path);
    P.Options := [poNoConsole];
    P.Execute;
  finally
    { Freeing a TProcess does not stop the child. }
    P.Free;
  end;
end;

function TrashItem(const Path: string): Boolean;
begin
  Result := NSFileManager.defaultManager.trashItemAtURL_resultingItemURL_error(
    NSURL.fileURLWithPath(NSStr(Path)), nil, nil);
end;

{ Moves the bundle into /Applications or ~/Applications; its new path, or
  '' when neither worked. }
function PerformMove(const Source: string): string;
var
  Dirs: array[0..1] of string;
  Dir, Destination: string;
  FM: NSFileManager;
  I: Integer;
begin
  Result := '';
  FM := NSFileManager.defaultManager;
  Dirs[0] := '/Applications';
  Dirs[1] := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + 'Applications';
  for I := 0 to High(Dirs) do
  begin
    Dir := Dirs[I];
    FM.createDirectoryAtPath_withIntermediateDirectories_attributes_error(
      NSStr(Dir), True, nil, nil);
    if not FM.isWritableFileAtPath(NSStr(Dir)) then
      Continue;
    Destination := IncludeTrailingPathDelimiter(Dir) + ExtractFileName(Source);
    if FM.fileExistsAtPath(NSStr(Destination)) and not TrashItem(Destination) then
      Continue;
    if not FM.moveItemAtPath_toPath_error(NSStr(Source), NSStr(Destination), nil) then
    begin
      if not FM.copyItemAtPath_toPath_error(NSStr(Source), NSStr(Destination), nil) then
        Continue;
      TrashItem(Source);
    end;
    StripQuarantine(Destination);
    Exit(Destination);
  end;
end;

function PromptMoveToApplicationsIfNeeded: Boolean;
var
  BundlePath, Source, Destination: string;
  Alert, Failure: NSAlert;
  Response: NSInteger;
begin
  Result := False;
  BundlePath := ExcludeTrailingPathDelimiter(NSBundle.mainBundle.bundlePath.UTF8String);
  { Only a real app bundle (not the bare development binary). }
  if LowerCase(ExtractFileExt(BundlePath)) <> '.app' then
    Exit;
  Source := TranslocationOriginal(BundlePath);
  if Source = '' then
    Source := BundlePath;
  if IsDevelopmentBuild(Source) then
    Exit;
  if Source <> BundlePath then
  begin
    if GetBoolPreference(RelaunchAttemptKey, False) then
      Exit;
    SetBoolPreference(RelaunchAttemptKey, True);
    if not StripQuarantine(Source) then
      Exit;
    Relaunch(Source);
    Exit(True);
  end;
  RemovePreference(RelaunchAttemptKey);
  if IsInApplicationsFolder(Source) then
    Exit;
  if GetBoolPreference(SuppressionKey, False) then
    Exit;

  Alert := NSAlert.alloc.init;
  try
    Alert.setMessageText(NSStr('Move ' + AppName + ' to your Applications folder?'));
    Alert.setInformativeText(NSStr(AppName + ' works best from the Applications ' +
      'folder, and automatic updates require it. It will move itself and reopen.'));
    Alert.addButtonWithTitle(NSStr('Move to Applications'));
    Alert.addButtonWithTitle(NSStr('Not Now'));
    Alert.setShowsSuppressionButton(True);
    Alert.suppressionButton.setTitle(NSStr('Don''t ask again'));
    Response := Alert.runModal;
    if Alert.suppressionButton.state = NSOnState then
      SetBoolPreference(SuppressionKey, True);
  finally
    Alert.release;
  end;
  if Response <> NSAlertFirstButtonReturn then
    Exit;

  Destination := PerformMove(Source);
  if Destination = '' then
  begin
    Failure := NSAlert.alloc.init;
    try
      Failure.setAlertStyle(NSWarningAlertStyle);
      Failure.setMessageText(NSStr('Couldn''t Move ' + AppName));
      Failure.setInformativeText(NSStr('Please quit ' + AppName +
        ' and drag it into the Applications folder yourself.'));
      Failure.runModal;
    finally
      Failure.release;
    end;
    Exit;
  end;
  Relaunch(Destination);
  Result := True;
end;

{$ELSE}

function PromptMoveToApplicationsIfNeeded: Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
