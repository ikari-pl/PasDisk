{ FullDiskAccessUI — the Full Disk Access startup prompt and the Settings
  window.

  OpenDiskApp.swift checkFullDiskAccessAtStartup + FullDiskAccess.swift
  promptIfNotGranted / resetPromptSuppression, and
  Views/Settings/SettingsView.swift. Preferences: fda_show_prompt_at_startup
  (default on) and fda_suppressed (default off), as the Swift app's
  @AppStorage / UserDefaults keys. }

unit FullDiskAccessUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics;

const
  PrefShowPromptAtStartup = 'fda_show_prompt_at_startup';
  PrefPromptSuppressed = 'fda_suppressed';

{ Call once, shortly after the main window appears: shows the alert when
  the startup check is on, the prompt was not suppressed, the app is not
  translocated and access is not granted. }
procedure PromptForFullDiskAccessAtStartup;

{ Opens (or brings forward) the Settings window. }
procedure ShowSettingsWindow;

implementation

uses
  PlatformAlert, PlatformFullDiskAccess, PlatformPreferences, PlatformImages,
  GuiColors;

const
  { System green / orange (reserved for success and warning states). }
  GrantedColor = TColor($0059C734);
  NotGrantedColor = TColor($000095FF);

procedure PromptForFullDiskAccessAtStartup;
var
  Suppressed: Boolean;
begin
  if not GetBoolPreference(PrefShowPromptAtStartup, True) then
    Exit;
  { FullDiskAccess.promptIfNotGranted: not from App Translocation, not
    when suppressed, not when already granted. }
  if Pos('/AppTranslocation/', ParamStr(0)) > 0 then
    Exit;
  if GetBoolPreference(PrefPromptSuppressed, False) or FullDiskAccessGranted then
    Exit;
  if ShowSuppressibleAlert('Full Disk Access Required',
    'OpenDisk needs Full Disk Access to analyze all files and folders on your ' +
    'system. You can grant this permission in System Settings > Privacy & ' +
    'Security > Full Disk Access.', ['Open Settings', 'Later'], Suppressed) = 0 then
    OpenFullDiskAccessSettings;
  if Suppressed then
    SetBoolPreference(PrefPromptSuppressed, True);
end;

type
  TSettingsWindow = class(TForm)
  private
    FGranted: Boolean;
    FStatusDot: TShape;
    FStatusText: TLabel;
    FCheckAgain: TButton;
    FOpenSettings: TButton;
    FAfterHint: TLabel;
    FStartupToggle: TCheckBox;
    FStartupHint: TLabel;
    FResetSuppression: TButton;
    FAccessCaption: TLabel;
    FSectionStartup, FSectionAbout: TControl;
    FAbout: TLabel;
    procedure CheckAgainClick(Sender: TObject);
    procedure OpenSettingsClick(Sender: TObject);
    procedure StartupToggleChange(Sender: TObject);
    procedure ResetSuppressionClick(Sender: TObject);
    function AddHeader(const Symbol, Title: string; AtTop: Integer): TControl;
    function AddLabel(const AText: string; AtTop, Size: Integer; Secondary: Boolean): TLabel;
    procedure UpdateStatus;
    procedure Layout;
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  SettingsWindow: TSettingsWindow = nil;

const
  Margin = 20;
  Indent = 28;

constructor TSettingsWindow.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Settings';
  Width := 600;
  Height := 500;
  Position := poScreenCenter;
  BorderIcons := [biSystemMenu];
  Color := clWindow;

  AddHeader('lock.shield', 'Full Disk Access', Margin);
  AddLabel('Status', Margin + 34, 13, False);
  FStatusDot := TShape.Create(Self);
  FStatusDot.Parent := Self;
  FStatusDot.Shape := stCircle;
  FStatusDot.SetBounds(Indent + 70, Margin + 37, 10, 10);
  FStatusDot.Pen.Style := psClear;
  FStatusText := AddLabel('', Margin + 34, 13, False);
  FStatusText.Left := Indent + 88;
  FCheckAgain := TButton.Create(Self);
  FCheckAgain.Parent := Self;
  FCheckAgain.Caption := 'Check Again';
  FCheckAgain.SetBounds(Width - Margin - 120, Margin + 28, 120, 28);
  FCheckAgain.Anchors := [akTop, akRight];
  FCheckAgain.OnClick := @CheckAgainClick;
  FAccessCaption := AddLabel('Full Disk Access allows OpenDisk to analyze all files ' +
    'and folders on your system for accurate disk usage information.',
    Margin + 66, 10, True);
  FOpenSettings := TButton.Create(Self);
  FOpenSettings.Parent := Self;
  FOpenSettings.Caption := 'Open Privacy && Security Settings';
  FOpenSettings.OnClick := @OpenSettingsClick;
  FAfterHint := AddLabel('After granting access, click ''Check Again'' to verify.', 0, 9, True);

  FSectionStartup := AddHeader('power', 'Startup Behavior', 0);
  FStartupToggle := TCheckBox.Create(Self);
  FStartupToggle.Parent := Self;
  FStartupToggle.Caption := 'Check Full Disk Access at startup';
  FStartupToggle.Checked := GetBoolPreference(PrefShowPromptAtStartup, True);
  FStartupToggle.OnChange := @StartupToggleChange;
  FStartupHint := AddLabel('Shows a prompt if Full Disk Access is not granted', 0, 10, True);
  FResetSuppression := TButton.Create(Self);
  FResetSuppression.Parent := Self;
  FResetSuppression.Caption := 'Reset Prompt Suppression';
  FResetSuppression.OnClick := @ResetSuppressionClick;

  FSectionAbout := AddHeader('info.circle', 'About Permissions', 0);
  FAbout := AddLabel('Why does OpenDisk need Full Disk Access?' + LineEnding + LineEnding +
    '• Analyze system files and protected folders' + LineEnding +
    '• Calculate accurate disk usage across all directories' + LineEnding +
    '• Access application containers and caches' + LineEnding +
    '• Provide complete disk analysis results', 0, 12, False);

  UpdateStatus;
end;

function TSettingsWindow.AddHeader(const Symbol, Title: string; AtTop: Integer): TControl;
var
  Panel: TPanel;
  Img: TImage;
  Bmp: TBitmap;
  L: TLabel;
begin
  Panel := TPanel.Create(Self);
  Panel.Parent := Self;
  Panel.BevelOuter := bvNone;
  Panel.ParentColor := True;
  Panel.SetBounds(Margin, AtTop, Width - 2 * Margin, 22);
  Panel.Anchors := [akLeft, akTop, akRight];
  Img := TImage.Create(Panel);
  Img.Parent := Panel;
  Img.SetBounds(0, 3, 16, 16);
  Img.Stretch := True;
  Img.Transparent := True;
  Bmp := SystemSymbolBitmap(Symbol, 32, SecondaryTextColor(clWindow));
  if Bmp <> nil then
  try
    Img.Picture.Assign(Bmp);
  finally
    Bmp.Free;
  end;
  L := TLabel.Create(Panel);
  L.Parent := Panel;
  L.Left := 22;
  L.Top := 2;
  L.Font.Size := 13;
  L.Font.Style := [fsBold];
  L.Caption := Title;
  Result := Panel;
end;

function TSettingsWindow.AddLabel(const AText: string; AtTop, Size: Integer;
  Secondary: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.Left := Indent;
  Result.Top := AtTop;
  Result.Font.Size := Size;
  if Secondary then
    Result.Font.Color := SecondaryTextColor(clWindow);
  Result.WordWrap := True;
  Result.AutoSize := True;
  Result.Width := Width - Indent - Margin;
  Result.Anchors := [akLeft, akTop, akRight];
  Result.Caption := AText;
end;

procedure TSettingsWindow.UpdateStatus;
begin
  FGranted := FullDiskAccessGranted;
  if FGranted then
  begin
    FStatusDot.Brush.Color := GrantedColor;
    FStatusText.Caption := 'Granted';
    FStatusText.Font.Color := GrantedColor;
  end
  else
  begin
    FStatusDot.Brush.Color := NotGrantedColor;
    FStatusText.Caption := 'Not Granted';
    FStatusText.Font.Color := NotGrantedColor;
  end;
  Layout;
end;

{ SettingsView: the 'open settings' button and its hint, and 'Reset Prompt
  Suppression', only while access is not granted. }
procedure TSettingsWindow.Layout;
var
  Y: Integer;
begin
  Y := FAccessCaption.Top + FAccessCaption.Height + 16;
  FOpenSettings.Visible := not FGranted;
  FAfterHint.Visible := not FGranted;
  if not FGranted then
  begin
    FOpenSettings.SetBounds(Indent, Y, 260, 28);
    Inc(Y, 32);
    FAfterHint.Top := Y;
    Inc(Y, FAfterHint.Height + 8);
  end;
  Inc(Y, 16);
  FSectionStartup.Top := Y;
  Inc(Y, 30);
  FStartupToggle.SetBounds(Indent, Y, Width - Indent - Margin, 22);
  Inc(Y, 22);
  FStartupHint.Left := Indent + 20;
  FStartupHint.Top := Y;
  Inc(Y, FStartupHint.Height + 8);
  FResetSuppression.Visible := not FGranted;
  if not FGranted then
  begin
    FResetSuppression.SetBounds(Indent, Y, 200, 28);
    Inc(Y, 36);
  end;
  Inc(Y, 16);
  FSectionAbout.Top := Y;
  Inc(Y, 30);
  FAbout.Top := Y;
end;

procedure TSettingsWindow.CheckAgainClick(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TSettingsWindow.OpenSettingsClick(Sender: TObject);
begin
  OpenFullDiskAccessSettings;
end;

procedure TSettingsWindow.StartupToggleChange(Sender: TObject);
begin
  SetBoolPreference(PrefShowPromptAtStartup, FStartupToggle.Checked);
end;

procedure TSettingsWindow.ResetSuppressionClick(Sender: TObject);
begin
  SetBoolPreference(PrefPromptSuppressed, False);
end;

procedure ShowSettingsWindow;
begin
  if SettingsWindow = nil then
    SettingsWindow := TSettingsWindow.Create(Application);
  SettingsWindow.UpdateStatus;
  SettingsWindow.Show;
  SettingsWindow.BringToFront;
end;

end.
