{ Main OpenDisk GUI — volume picker first, then analysis (list + rings).

  Layout mirrors Swift ContentView → DevicePickerView → DiskAnalysisView:
  home screen is disk selection; scanning only starts after a choice. }

unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, ComCtrls, Buttons, RingsChart, FileTree, Traversal,
  ChartItem, Formatters, Collector, ProtectedPaths, Volumes, PlatformVolumes, PlatformAppearance,
  GuiColors, BreadcrumbBar, TextTrim, EmptyStateView, ScanTopology, ScanStatusBar;

type
  TUIMode = (umPicker, umScanning, umAnalysis);

  TScanThread = class(TThread)
  private
    FPath: string;
    FTree: TFileTree;
    FBytes: Int64;
    FItems: Integer;
  FError: string;
    FUnreadable: Integer;
    FCheckingChanges: Integer;
    { Newest partial snapshot not yet taken by the UI (od-31j.45). }
    FPartialLock: TRTLCriticalSection;
    FPartial: TFileTree;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    { Called on the scan thread: keeps only the newest snapshot. }
    procedure OfferPartial(Tree: TFileTree);
    { Called on the UI thread: the newest snapshot (caller owns), or nil. }
    function TakePartial: TFileTree;
    { True while the cache is checked against the change journal. }
    function CheckingChanges: Boolean;
    procedure SetCheckingChanges(Value: Boolean);
    { Valid only after WaitFor. }
    property Tree: TFileTree read FTree;
    property Error: string read FError;
    property Unreadable: Integer read FUnreadable;
    { Progress counters, written by the scan thread and read by the UI. }
    function Bytes: Int64;
    function Items: Integer;
    procedure SetProgress(ABytes: Int64; AItems: Integer);
  end;

  TMainForm = class(TForm)
  private
    FMode: TUIMode;
    { Picker }
    FPicker: TPanel;
    FPickerTitle: TLabel;
    FPickerSub: TLabel;
    FVolList: TListBox;
    FFolderBtn: TButton;
  FRefreshVolBtn: TButton;
    FPickerState: TEmptyStateView;
    { Replaces the list and chart: FDA required, unreadable, empty. }
    FAnalysisState: TEmptyStateView;
    FNeedsFullDiskAccess: Boolean;
    FVolumes: TVolumeInfoArray;
    FVolHover: Integer;
    { Analysis chrome }
    FAnalysis: TPanel;
    FNav: TPanel;
    FDisksBtn: TButton;
    FBackBtn: TButton;
    FCrumbBar: TBreadcrumbBar;
    FRefreshBtn: TButton;
    FBody: TPanel;
    FListPanel: TPanel;
    FListHeader: TLabel;
    FList: TListBox;
    { Largest size among the listed children (ScanResultsView.swift maxSize)
      and the row under the pointer, -1 for none. }
    FListMaxSize: Int64;
    FListHover: Integer;
    FChartPanel: TPanel;
    FChart: TRingsChart;
    FCollectorPanel: TPanel;
    FCollectorLabel: TLabel;
    FDeleteButton: TButton;
    { CollectorBar deleting / done phases (od-31j.46). }
    FCollectorDetail: TLabel;
    FDeleteBar: TProgressBar;
    FDeleteJob: TDeleteJob;
    FDeletePoll: TTimer;
    FDoneTimer: TTimer;
    FStatus: TStatusBar;
    FCollector: TCollector;
    FTree: TFileTree;
    FCurrentPath: string;
    FRootPath: string;
    FRootName: string;
    FRootTotal: QWord;
    FRootFree: QWord;
    { DiskAnalysisView ScanStatusBar and the scan it describes. }
    FScanBar: TScanStatusBar;
    FScanStart: TDateTime;
     FScanThread: TScanThread;
     FPoll: TTimer;
    FBreadcrumbs: TStringList;
    procedure BuildUI;
    procedure ShowPicker;
    procedure ShowAnalysis;
    procedure RefreshVolumes;
    procedure StyleChrome;
    procedure StartScan(const APath, AName: string; Total, FreeBytes: QWord);
     procedure OnPoll(Sender: TObject);
    { Stops a running scan (window close, Disks) without waiting for the
      walk to finish; its partial tree is discarded. }
    procedure CancelScan;
     procedure OnThemeChange(Sender: TObject);
     procedure ApplyTheme;
    procedure ScanFinished;
    procedure ShowNode(const APath: string);
    procedure RefreshList;
    procedure RefreshCollector;
    procedure VolListDrawItem(Control: TWinControl; Index: Integer;
      ARect: TRect; State: TOwnerDrawState);
    procedure VolListDblClick(Sender: TObject);
    procedure VolListKeyPress(Sender: TObject; var Key: Char);
    procedure VolListMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure VolListMouseLeave(Sender: TObject);
    procedure SetVolHover(Index: Integer);
    procedure FolderClick(Sender: TObject);
    procedure RefreshVolClick(Sender: TObject);
    procedure ListDblClick(Sender: TObject);
    procedure CrumbNavigate(const Path: string);
    procedure ListDrawItem(Control: TWinControl; Index: Integer;
      ARect: TRect; State: TOwnerDrawState);
    procedure ListMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ListMouseLeave(Sender: TObject);
    procedure SetListHover(Index: Integer);
    procedure ChartSelect(Sender: TObject; const APath: string; IsCenter: Boolean);
    procedure DisksClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure DeletePollTick(Sender: TObject);
    procedure DoneTimerTick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormResize(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure OpenFDA(Sender: TObject);
    procedure RelaunchForFDA(Sender: TObject);
    procedure RescanState(Sender: TObject);
    procedure ShowAnalysisState(const Symbol, Title, Description: string;
      const Captions: array of string; const Handlers: array of TNotifyEvent);
    procedure HideAnalysisState;
    procedure ShowPartial(Partial: TFileTree);
    function ScanFraction(Bytes: Int64): Double;
    procedure RefreshVolumeCapacity;
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  MainForm: TMainForm;

implementation

uses
  LCLType, LCLIntf, PlatformFS, PlatformImages, PlatformFullDiskAccess,
  PlatformShell;

const
  { LCL system colors map to semantic Cocoa colors on macOS. }
  CBg       = clWindow;
  CPanel    = clBtnFace;
  CPanel2   = cl3DLight;
  CInk      = clWindowText;
  CAccent   = clHighlight;
  CBarTrack = clBtnShadow;
  CBarFill  = clHighlight;

threadvar
  { The scan thread running on this OS thread: TScanProgress and
    TScanCancelled are plain procedures, so the thunks find their thread
    here. }
  ActiveScanThread: TScanThread;

function ResolvePath(const Path: string): string;
begin
  Result := ResolveRealPath(Path);
end;

constructor TScanThread.Create(const APath: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPath := APath;
  FTree := nil;
  FBytes := 0;
  FItems := 0;
  FUnreadable := 0;
  InitCriticalSection(FPartialLock);
  FPartial := nil;
end;

destructor TScanThread.Destroy;
begin
  FPartial.Free;
  DoneCriticalSection(FPartialLock);
  inherited Destroy;
end;

procedure TScanThread.OfferPartial(Tree: TFileTree);
var
  Old: TFileTree;
begin
  EnterCriticalSection(FPartialLock);
  Old := FPartial;
  FPartial := Tree;
  LeaveCriticalSection(FPartialLock);
  Old.Free;
end;

function TScanThread.TakePartial: TFileTree;
begin
  EnterCriticalSection(FPartialLock);
  Result := FPartial;
  FPartial := nil;
  LeaveCriticalSection(FPartialLock);
end;

function TScanThread.CheckingChanges: Boolean;
begin
  Result := InterLockedCompareExchange(FCheckingChanges, 0, 0) <> 0;
end;

procedure TScanThread.SetCheckingChanges(Value: Boolean);
begin
  InterLockedExchange(FCheckingChanges, Ord(Value));
end;

procedure ScanPhaseThunk(CheckingChanges: Boolean);
begin
  if ActiveScanThread <> nil then
    ActiveScanThread.SetCheckingChanges(CheckingChanges);
end;

procedure ScanPartialThunk(Tree: TFileTree);
begin
  if ActiveScanThread <> nil then
    ActiveScanThread.OfferPartial(Tree)
  else
    Tree.Free;
end;

procedure TScanThread.SetProgress(ABytes: Int64; AItems: Integer);
begin
  InterLockedExchange64(FBytes, ABytes);
  InterLockedExchange(FItems, AItems);
end;

function TScanThread.Bytes: Int64;
begin
  Result := InterLockedCompareExchange64(FBytes, 0, 0);
end;

function TScanThread.Items: Integer;
begin
  Result := InterLockedCompareExchange(FItems, 0, 0);
end;

procedure ScanProgressThunk(BytesScanned: Int64; ItemsScanned: Integer);
begin
  if ActiveScanThread <> nil then
    ActiveScanThread.SetProgress(BytesScanned, ItemsScanned);
end;

function ScanCancelledThunk: Boolean;
begin
  Result := TThread.CheckTerminated;
end;

procedure TScanThread.Execute;
begin
  ActiveScanThread := Self;
  try
    try
      { ScanEngine.swift performScan: '/' is the whole boot volume group,
        other paths include the Data volume behind the firmlinks (and its
        alias); a cancelled scan's partial tree is discarded. }
      { The app always scans through the cache (ScanEngine.swift
        scanRootTreeUsingCache). }
      FTree := ScanForAnalysis(FPath, @ScanProgressThunk,
        @ScanCancelledThunk, @FUnreadable, @ScanPartialThunk, True,
        @ScanPhaseThunk);
      if Terminated then
        FreeAndNil(FTree);
    except
      on E: Exception do
        FError := E.Message;
    end;
  finally
    if ActiveScanThread = Self then
      ActiveScanThread := nil;
  end;
end;

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 0);
  Caption := 'OpenDisk';
  Width := 1120;
  Height := 740;
  Position := poScreenCenter;
  KeyPreview := True;
  Color := CBg;
  OnDestroy := @FormDestroy;
  OnKeyDown := @FormKeyDown;
  OnResize := @FormResize;
  OnActivate := @FormActivate;
  FCollector := TCollector.Create;
  FBreadcrumbs := TStringList.Create;
  FTree := nil;
  FScanThread := nil;
  FMode := umPicker;
  SetLength(FVolumes, 0);
  BuildUI;
  StyleChrome;
  FPoll := TTimer.Create(Self);
  FPoll.Interval := 120;
  FPoll.Enabled := False;
  FPoll.OnTimer := @OnPoll;
  WatchAppearanceChanges(@OnThemeChange);
  ShowPicker;
  RefreshVolumes;
  { Screenshots and automation: OPENDISK_GUI_SCAN=<folder> scans that folder
    at launch instead of waiting for the folder dialog (and
    OPENDISK_GUI_SHOW=<subfolder> then opens a folder inside it). }
  if GetEnvironmentVariable('OPENDISK_GUI_SCAN') <> '' then
    StartScan(GetEnvironmentVariable('OPENDISK_GUI_SCAN'), '', 0, 0);
end;

procedure TMainForm.BuildUI;
begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;
  FStatus.SimpleText := 'Select a disk';

  { --- Picker --- }
  FPicker := TPanel.Create(Self);
  FPicker.Parent := Self;
  FPicker.Align := alClient;
  FPicker.BevelOuter := bvNone;
  FPicker.Color := CBg;

  FPickerTitle := TLabel.Create(Self);
  FPickerTitle.Parent := FPicker;
  FPickerTitle.Caption := 'OpenDisk';
  FPickerTitle.Font.Size := 28;
  FPickerTitle.Font.Style := [fsBold];
  FPickerTitle.Font.Color := CInk;
  FPickerTitle.Left := 48;
  FPickerTitle.Top := 40;

  FPickerSub := TLabel.Create(Self);
  FPickerSub.Parent := FPicker;
  FPickerSub.Caption := 'Select a disk';
  FPickerSub.Font.Size := 13;
  FPickerSub.Font.Color := SecondaryTextColor(CBg);
  FPickerSub.Left := 50;
  FPickerSub.Top := 86;

  FVolList := TListBox.Create(Self);
  FVolList.Parent := FPicker;
  FVolList.Left := 48;
  FVolList.Top := 130;
  FVolList.Width := 460;
  FVolList.Height := 420;
  FVolList.Style := lbOwnerDrawFixed;
  FVolList.ItemHeight := 60;
  FVolList.BorderStyle := bsNone;
  FVolList.Color := CPanel;
  FVolList.OnDrawItem := @VolListDrawItem;
  { The accent selection shows focus, as in Swift lists; no extra
    focus rectangle. }
  FVolList.Options := FVolList.Options - [lboDrawFocusRect];
  FVolList.OnDblClick := @VolListDblClick;
  FVolList.OnKeyPress := @VolListKeyPress;
  FVolList.OnMouseMove := @VolListMouseMove;
  FVolList.OnMouseLeave := @VolListMouseLeave;
  FVolHover := -1;

  { DevicePickerView: ContentUnavailableView in place of the rows. }
  FPickerState := TEmptyStateView.Create(Self);
  FPickerState.Parent := FPicker;
  FPickerState.Color := CPanel;
  FPickerState.Visible := False;
  FPickerState.SetState('externaldrive.badge.questionmark', 'No Disks Found',
    'Connected volumes appear here automatically', [], []);

  FFolderBtn := TButton.Create(Self);
  FFolderBtn.Parent := FPicker;
  FFolderBtn.Caption := 'Scan Folder…';
  FFolderBtn.Left := 48;
  FFolderBtn.Top := 570;
  FFolderBtn.Width := 140;
  FFolderBtn.Height := 32;
  FFolderBtn.OnClick := @FolderClick;

  FRefreshVolBtn := TButton.Create(Self);
  FRefreshVolBtn.Parent := FPicker;
  FRefreshVolBtn.Caption := 'Refresh';
  FRefreshVolBtn.Left := FFolderBtn.Left + FFolderBtn.Width + 8;
  FRefreshVolBtn.Top := 570;
  FRefreshVolBtn.Width := 100;
  FRefreshVolBtn.Height := 32;
  FRefreshVolBtn.OnClick := @RefreshVolClick;


  { --- Analysis --- }
  FAnalysis := TPanel.Create(Self);
  FAnalysis.Parent := Self;
  FAnalysis.Align := alClient;
  FAnalysis.BevelOuter := bvNone;
  FAnalysis.Color := CBg;
  FAnalysis.Visible := False;

  FNav := TPanel.Create(Self);
  FNav.Parent := FAnalysis;
  FNav.Align := alTop;
  FNav.Height := 52;
  FNav.BevelOuter := bvNone;
  FNav.Color := CPanel;

  FDisksBtn := TButton.Create(Self);
  FDisksBtn.Parent := FNav;
  FDisksBtn.Caption := 'Unmount';
  FDisksBtn.Hint := 'Unmount and clear scan data (Cmd-[)';
  FDisksBtn.ShowHint := True;
  FDisksBtn.Left := 16;
  FDisksBtn.Top := 12;
  FDisksBtn.Width := 72;
  FDisksBtn.Height := 28;
  FDisksBtn.OnClick := @DisksClick;

  FBackBtn := TButton.Create(Self);
  FBackBtn.Parent := FNav;
  FBackBtn.Caption := '‹';
  FBackBtn.Left := 96;
  FBackBtn.Top := 12;
  FBackBtn.Width := 36;
  FBackBtn.Height := 28;
  FBackBtn.OnClick := @BackClick;

  FCrumbBar := TBreadcrumbBar.Create(Self);
  FCrumbBar.Parent := FNav;
  FCrumbBar.Left := 140;
  FCrumbBar.Top := 12;
  FCrumbBar.Height := 28;
  FCrumbBar.Color := CPanel;
  FCrumbBar.OnNavigate := @CrumbNavigate;

  FRefreshBtn := TButton.Create(Self);
  FRefreshBtn.Parent := FNav;
  FRefreshBtn.Caption := 'Refresh';
  FRefreshBtn.Hint := 'Rescan the current folder (Cmd-R)';
  FRefreshBtn.ShowHint := True;
  FRefreshBtn.Width := 88;
  FRefreshBtn.Height := 28;
  FRefreshBtn.Top := 12;
  FRefreshBtn.Anchors := [akTop, akRight];
  FRefreshBtn.OnClick := @RefreshClick;

  { The trail fills the space up to the Refresh button and follows resizes. }
  FCrumbBar.AnchorSideRight.Control := FRefreshBtn;
  FCrumbBar.AnchorSideRight.Side := asrLeft;
  FCrumbBar.BorderSpacing.Right := 12;
  FCrumbBar.Anchors := [akLeft, akTop, akRight];

  FCollectorPanel := TPanel.Create(Self);
  FCollectorPanel.Parent := FAnalysis;
  FCollectorPanel.Align := alBottom;
  FCollectorPanel.Height := 56;
  FCollectorPanel.BevelOuter := bvNone;
  FCollectorPanel.Color := CPanel2;

  FCollectorLabel := TLabel.Create(Self);
  FCollectorLabel.Parent := FCollectorPanel;
  FCollectorLabel.Left := 20;
  FCollectorLabel.Top := 18;
  FCollectorLabel.Font.Color := SecondaryTextColor(CPanel2);
  FCollectorLabel.Caption := 'Collector empty — double-click a file to stage deletion.';

  FDeleteButton := TButton.Create(Self);
  FDeleteButton.Parent := FCollectorPanel;
  FDeleteButton.Caption := 'Delete collected';
  FDeleteButton.Width := 140;
  FDeleteButton.Height := 28;
  FDeleteButton.Top := 14;
  FDeleteButton.Anchors := [akTop, akRight];
  FDeleteButton.OnClick := @DeleteClick;
  FDeleteButton.Enabled := False;

  FCollectorDetail := TLabel.Create(Self);
  FCollectorDetail.Parent := FCollectorPanel;
  FCollectorDetail.Left := 20;
  FCollectorDetail.Top := 32;
  FCollectorDetail.Font.Size := 10;
  FCollectorDetail.Font.Color := SecondaryTextColor(CPanel2);
  FCollectorDetail.Visible := False;

  FDeleteBar := TProgressBar.Create(Self);
  FDeleteBar.Parent := FCollectorPanel;
  FDeleteBar.Left := 20;
  FDeleteBar.Top := 48;
  FDeleteBar.Height := 4;
  FDeleteBar.Anchors := [akLeft, akTop, akRight];
  FDeleteBar.Visible := False;

  FDeletePoll := TTimer.Create(Self);
  FDeletePoll.Enabled := False;
  FDeletePoll.Interval := 33;
  FDeletePoll.OnTimer := @DeletePollTick;

  FDoneTimer := TTimer.Create(Self);
  FDoneTimer.Enabled := False;
  FDoneTimer.Interval := 2000;
  FDoneTimer.OnTimer := @DoneTimerTick;

  { Spans the window bottom, below the collector (created after it, so
    the bottom alignment puts it lowest). }
  FScanBar := TScanStatusBar.Create(Self);
  FScanBar.Parent := FAnalysis;
  FScanBar.Align := alBottom;
  FScanBar.Top := FCollectorPanel.Top + FCollectorPanel.Height;

  FBody := TPanel.Create(Self);
  FBody.Parent := FAnalysis;
  FBody.Align := alClient;
  FBody.BevelOuter := bvNone;
  FBody.Color := CBg;

  FListPanel := TPanel.Create(Self);
  FListPanel.Parent := FBody;
  FListPanel.Align := alLeft;
  FListPanel.Width := 440;
  FListPanel.BevelOuter := bvNone;
  FListPanel.Color := CPanel;

  FListHeader := TLabel.Create(Self);
  FListHeader.Parent := FListPanel;
  FListHeader.Align := alTop;
  FListHeader.AutoSize := False;
  FListHeader.Height := 36;
  FListHeader.Layout := tlCenter;
  FListHeader.BorderSpacing.Left := 16;
  FListHeader.Caption := 'Largest first';
  FListHeader.Font.Size := 10;
  FListHeader.Font.Color := SecondaryTextColor(CPanel);

  FList := TListBox.Create(Self);
  FList.Parent := FListPanel;
  FList.Align := alClient;
  FList.BorderStyle := bsNone;
  FList.Color := CPanel;
  FList.Font.Color := CInk;
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := 36;
  FList.OnDrawItem := @ListDrawItem;
  { The accent selection shows focus, as in Swift lists; no extra
    focus rectangle. }
  FList.Options := FList.Options - [lboDrawFocusRect];
  FList.OnMouseMove := @ListMouseMove;
  FList.OnMouseLeave := @ListMouseLeave;
  FList.OnDblClick := @ListDblClick;
  FListHover := -1;

  FChartPanel := TPanel.Create(Self);
  FChartPanel.Parent := FBody;
  FChartPanel.Align := alClient;
  FChartPanel.BevelOuter := bvNone;
  FChartPanel.Color := CBg;
  FChartPanel.BorderSpacing.Around := 12;

  FChart := TRingsChart.Create(Self);
  FChart.Parent := FChartPanel;
  FChart.Align := alClient;
  FChart.OnSelect := @ChartSelect;

  { DiskAnalysisView emptyStateView: covers the list and the chart. }
  FAnalysisState := TEmptyStateView.Create(Self);
  FAnalysisState.Parent := FBody;
  { Over the list as well as the chart, like Swift's emptyStateView. }
  FAnalysisState.SetBounds(0, 0, FBody.ClientWidth, FBody.ClientHeight);
  FAnalysisState.Anchors := [akLeft, akTop, akRight, akBottom];
  FAnalysisState.Color := CBg;
  FAnalysisState.Visible := False;
end;

procedure TMainForm.ApplyTheme;
begin
  Color := CBg;
  FPicker.Color := CBg;
  FAnalysis.Color := CBg;
  FBody.Color := CBg;
  FChartPanel.Color := CBg;
  FAnalysisState.Color := CBg;
  FPickerState.Color := CPanel;
  FNav.Color := CPanel;
  FListPanel.Color := CPanel;
  FVolList.Color := CPanel;
  FList.Color := CPanel;
  FCollectorPanel.Color := CPanel2;

  FPickerTitle.Font.Color := CInk;
  FPickerSub.Font.Color := SecondaryTextColor(CBg);
  FCrumbBar.Color := CPanel;
  FCollectorLabel.Font.Color := SecondaryTextColor(CPanel2);
  FListHeader.Font.Color := SecondaryTextColor(CPanel);
  FList.Font.Color := CInk;
  FChart.Color := CBg;

  Invalidate;
  FVolList.Invalidate;
  FList.Invalidate;
  FChart.AppearanceChanged;
end;

procedure TMainForm.OnThemeChange(Sender: TObject);
begin
  ApplyTheme;
end;

procedure TMainForm.StyleChrome;
begin
  ApplyTheme;
  FRefreshBtn.Left := Width - FRefreshBtn.Width - 24;
  FDeleteButton.Left := Width - FDeleteButton.Width - 24;
end;

procedure TMainForm.FormResize(Sender: TObject);
begin
  FRefreshBtn.Left := Max(200, Width - FRefreshBtn.Width - 24);
  FDeleteButton.Left := Max(200, Width - FDeleteButton.Width - 24);
  FVolList.Width := Min(560, Max(420, Width - 96));
  FVolList.Height := Max(200, Height - 260);
  FFolderBtn.Top := FVolList.Top + FVolList.Height + 12;
  FRefreshVolBtn.Top := FFolderBtn.Top;
  FPickerState.BoundsRect := FVolList.BoundsRect;
end;

procedure TMainForm.FormActivate(Sender: TObject);
begin
  { DiskAnalysisView: retry when the app comes back from System Settings. }
  if (FMode = umAnalysis) and FNeedsFullDiskAccess then
    StartScan(FRootPath, FRootName, FRootTotal, FRootFree);
end;

procedure TMainForm.ShowAnalysisState(const Symbol, Title, Description: string;
  const Captions: array of string; const Handlers: array of TNotifyEvent);
begin
  FAnalysisState.SetState(Symbol, Title, Description, Captions, Handlers);
  FAnalysisState.Visible := True;
  FAnalysisState.BringToFront;
end;

procedure TMainForm.HideAnalysisState;
begin
  FAnalysisState.Visible := False;
  FNeedsFullDiskAccess := False;
end;

procedure TMainForm.OpenFDA(Sender: TObject);
begin
  OpenFullDiskAccessSettings;
end;

procedure TMainForm.RelaunchForFDA(Sender: TObject);
begin
  if LaunchNewInstance then Application.Terminate;
end;

procedure TMainForm.RescanState(Sender: TObject);
begin
  StartScan(FRootPath, FRootName, FRootTotal, FRootFree);
end;

procedure TMainForm.ShowPicker;
begin
  FMode := umPicker;
  FAnalysis.Visible := False;
  FPicker.Visible := True;
  FPicker.BringToFront;
  FStatus.Visible := True;
  FStatus.SimpleText := 'Select a disk to analyze';
  Caption := 'OpenDisk';
end;

procedure TMainForm.ShowAnalysis;
begin
  FMode := umAnalysis;
  FPicker.Visible := False;
  FAnalysis.Visible := True;
  FAnalysis.BringToFront;
  HideAnalysisState;
  StyleChrome;
end;

procedure TMainForm.RefreshVolumes;
var
  I: Integer;
begin
  ClearVolumeIconCache;
  FVolumes := ListVolumes;
  { Screenshots: OPENDISK_GUI_NO_VOLUMES=1 shows the empty picker. }
  if GetEnvironmentVariable('OPENDISK_GUI_NO_VOLUMES') = '1' then
    FVolumes := nil;
  FVolList.Items.BeginUpdate;
  try
    FVolList.Clear;
    for I := 0 to High(FVolumes) do
      FVolList.Items.Add(FVolumes[I].Name);
  finally
    FVolList.Items.EndUpdate;
  end;
  FPickerState.BoundsRect := FVolList.BoundsRect;
  FPickerState.Visible := FVolList.Items.Count = 0;
  if FPickerState.Visible then
    FPickerState.BringToFront;
  if FVolList.Items.Count > 0 then
    FVolList.ItemIndex := 0;
  FStatus.SimpleText := Format('%d volume(s)', [Length(FVolumes)]);
end;

procedure TMainForm.VolListDrawItem(Control: TWinControl; Index: Integer;
  ARect: TRect; State: TOwnerDrawState);
var
  RowInk, RowBg: TColor;
  LB: TListBox;
  Vol: TVolumeInfo;
  UsedFrac: Double;
  Bar, Fill: TRect;
  Used, Total: string;
  Selected: Boolean;
  SelectedTrack: TColor;
begin
  LB := Control as TListBox;
  if (Index < 0) or (Index > High(FVolumes)) then
    Exit;
  Vol := FVolumes[Index];
  Selected := odSelected in State;
  LB.Canvas.Brush.Color := ColorToRGB(CPanel);
  LB.Canvas.Brush.Style := bsSolid;
  LB.Canvas.FillRect(ARect);
  { DevicePickerView rows: accent background when selected, a faint wash
    on hover (as in the folder rows). }
  if Selected or (Index = FVolHover) then
  begin
    if Selected then
      LB.Canvas.Brush.Color := ColorToRGB(clHighlight)
    else
    begin
      RowInk := SecondaryTextColor(CPanel);
      RowBg := ColorToRGB(CPanel);
      LB.Canvas.Brush.Color := RGBToColor(
        (Red(RowInk) + 7 * Red(RowBg)) div 8,
        (Green(RowInk) + 7 * Green(RowBg)) div 8,
        (Blue(RowInk) + 7 * Blue(RowBg)) div 8);
    end;
    LB.Canvas.Pen.Style := psClear;
    LB.Canvas.RoundRect(ARect.Left + 2, ARect.Top + 2, ARect.Right - 2,
      ARect.Bottom - 2, 8, 8);
    LB.Canvas.Pen.Style := psSolid;
  end;

  DrawVolumeIcon(LB.Canvas, Rect(ARect.Left + 8, ARect.Top + 10,
    ARect.Left + 44, ARect.Top + 46), Vol.Path);
  LB.Canvas.Brush.Style := bsClear;
  if Selected then
    LB.Canvas.Font.Color := ColorToRGB(clHighlightText)
  else
    LB.Canvas.Font.Color := ColorToRGB(CInk);
  LB.Canvas.Font.Size := 13;
  LB.Canvas.Font.Style := [fsBold];
  LB.Canvas.TextOut(ARect.Left + 56, ARect.Top + 8, Vol.Name);

  if Vol.TotalBytes > 0 then
  begin
    Used := FormatFileSize(Int64(Vol.TotalBytes - Vol.AvailableBytes));
    Total := FormatFileSize(Int64(Vol.TotalBytes));
    if Selected then
      LB.Canvas.Font.Color := SecondaryTextColor(clHighlight, clHighlightText)
    else
      LB.Canvas.Font.Color := SecondaryTextColor(CPanel);
    LB.Canvas.Font.Size := 10;
    LB.Canvas.Font.Style := [];
    LB.Canvas.TextOut(ARect.Left + 56, ARect.Top + 28, Used + ' / ' + Total);
    UsedFrac := Double(Vol.TotalBytes - Vol.AvailableBytes) / Double(Vol.TotalBytes);
    if UsedFrac < 0 then UsedFrac := 0;
    if UsedFrac > 1 then UsedFrac := 1;
    Bar := Rect(ARect.Left + 56, ARect.Top + 45, ARect.Left + 180, ARect.Top + 51);
    { StorageProgressBar: no outline, fully rounded ends. }
    LB.Canvas.Brush.Style := bsSolid;
    LB.Canvas.Pen.Style := psClear;
    if Selected then
    begin
      SelectedTrack := RGBToColor(
        (Red(ColorToRGB(clHighlightText)) + Red(ColorToRGB(clHighlight))) div 2,
        (Green(ColorToRGB(clHighlightText)) + Green(ColorToRGB(clHighlight))) div 2,
        (Blue(ColorToRGB(clHighlightText)) + Blue(ColorToRGB(clHighlight))) div 2);
      LB.Canvas.Brush.Color := SelectedTrack;
    end
    else
      LB.Canvas.Brush.Color := ColorToRGB(CBarTrack);
    LB.Canvas.RoundRect(Bar.Left, Bar.Top, Bar.Right, Bar.Bottom, 6, 6);
    Fill := Bar;
    Fill.Right := Fill.Left + Round((Fill.Right - Fill.Left) * UsedFrac);
    if Selected then
      LB.Canvas.Brush.Color := ColorToRGB(clHighlightText)
    else
      LB.Canvas.Brush.Color := ColorToRGB(CBarFill);
    if Fill.Right > Fill.Left then
      LB.Canvas.RoundRect(Fill.Left, Fill.Top, Fill.Right, Fill.Bottom, 6, 6);
    LB.Canvas.Pen.Style := psSolid;
  end;
  LB.Canvas.Pen.Color := ColorToRGB(SecondaryTextColor(CPanel));
  LB.Canvas.MoveTo(ARect.Right - 18, ARect.Top + 26);
  LB.Canvas.LineTo(ARect.Right - 14, ARect.Top + 30);
  LB.Canvas.LineTo(ARect.Right - 18, ARect.Top + 34);
  if Index < LB.Items.Count - 1 then
  begin
    LB.Canvas.Pen.Color := ColorToRGB(SecondaryTextColor(CPanel));
    LB.Canvas.Line(ARect.Left, ARect.Bottom - 1, ARect.Right, ARect.Bottom - 1);
  end;
end;

procedure TMainForm.SetVolHover(Index: Integer);
begin
  if FVolHover <> Index then
  begin
    FVolHover := Index;
    FVolList.Invalidate;
  end;
end;

procedure TMainForm.VolListMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  SetVolHover(FVolList.ItemAtPos(Point(X, Y), True));
end;

procedure TMainForm.VolListMouseLeave(Sender: TObject);
begin
  SetVolHover(-1);
end;

procedure TMainForm.VolListDblClick(Sender: TObject);
var
  I: Integer;
begin
  I := FVolList.ItemIndex;
  if (I < 0) or (I > High(FVolumes)) then
    Exit;
  StartScan(FVolumes[I].Path, FVolumes[I].Name,
    FVolumes[I].TotalBytes, FVolumes[I].AvailableBytes);
end;

procedure TMainForm.VolListKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    VolListDblClick(Sender);
  end;
end;

procedure TMainForm.FolderClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := GetUserDir;
  if SelectDirectory('Choose a folder to analyze', Dir, Dir) then
    StartScan(Dir, ExtractFileName(ExcludeTrailingPathDelimiter(Dir)), 0, 0);
end;

procedure TMainForm.RefreshVolClick(Sender: TObject);
begin
  RefreshVolumes;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  StopWatchingAppearance;
  CancelScan;
  FTree.Free;
  FCollector.Free;
  FBreadcrumbs.Free;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_Z) and (ssMeta in Shift) and (FMode = umAnalysis) then
  begin
    if FCollector.Undo then
      RefreshCollector;
    Key := 0;
  end
  else if (Key = VK_OEM_4) and (ssMeta in Shift) and (FMode in [umAnalysis, umScanning]) then
  begin
    DisksClick(nil);
    Key := 0;
  end
  else if (Key = VK_R) and (ssMeta in Shift) and (FMode = umAnalysis) then
  begin
    RefreshClick(nil);
    Key := 0;
  end;
end;

procedure TMainForm.StartScan(const APath, AName: string; Total, FreeBytes: QWord);
var
  Expanded: string;
  RootChanged: Boolean;
begin
  Expanded := ResolvePath(APath);
  RootChanged := Expanded <> FRootPath;
  if (IncludeTrailingPathDelimiter(Expanded) = PathDelim) and
    (not FullDiskAccessGranted) then
  begin
    FRootPath := Expanded;
    FRootName := AName;
    FRootTotal := Total;
    FRootFree := FreeBytes;
    ShowAnalysis;
    FreeAndNil(FTree);
    FChart.Root := nil;
    FList.Clear;
    ShowAnalysisState('exclamationmark.shield', 'Full Disk Access Required',
      'OpenDisk needs Full Disk Access to analyze your entire system. Turn it ' +
      'on in System Settings, then quit and reopen OpenDisk. macOS only ' +
      'applies the change to a freshly launched app.',
      ['Open System Settings', 'Quit && Reopen'], [@OpenFDA, @RelaunchForFDA]);
    FNeedsFullDiskAccess := True;
    Exit;
  end;
  if not DirectoryExists(ResolveDataVolumeAlias(Expanded)) then
  begin
    MessageDlg('Not a directory:' + LineEnding + Expanded, mtError, [mbOK], 0);
    Exit;
  end;
  if FScanThread <> nil then
  begin
    MessageDlg('A scan is already running.', mtInformation, [mbOK], 0);
    Exit;
  end;
  FreeAndNil(FTree);
  FChart.Root := nil;
  FList.Clear;
  FRootPath := Expanded;
  FRootName := AName;
  if FRootName = '' then
    FRootName := ExtractFileName(ExcludeTrailingPathDelimiter(Expanded));
  if FRootName = '' then
    FRootName := Expanded;
  FRootTotal := Total;
  FRootFree := FreeBytes;
  FCurrentPath := Expanded;
  FBreadcrumbs.Clear;
  { Swift keeps the collector for the analysed root (failed deletions
    stay staged across the rescan); a different root starts afresh. }
  if RootChanged then
    FCollector.Clear;
  RefreshCollector;
  FMode := umScanning;
  ShowAnalysis;
  FCrumbBar.SetPath(Expanded, FRootName, Expanded);
  Caption := FRootName;
  { The analysis window has its own status bar. }
  FStatus.Visible := False;
  FScanStart := Now;
  FScanBar.SetTotals(0, 0);
  FScanBar.SetScanning(0, 0, sspScanning, ScanFraction(0), FScanStart);
  RefreshVolumeCapacity;
  { Disks stays enabled: it cancels the scan. }
  FBackBtn.Enabled := False;
  FRefreshBtn.Enabled := False;
  FScanThread := TScanThread.Create(Expanded);
  FScanThread.Start;
  FPoll.Enabled := True;
end;

procedure TMainForm.OnPoll(Sender: TObject);
var
  Phase: TScanStatusPhase;
begin
  if FScanThread = nil then
  begin
    FPoll.Enabled := False;
    Exit;
  end;
  if FScanThread.CheckingChanges then
    Phase := sspCheckingChanges
  else
    Phase := sspScanning;
  FScanBar.SetScanning(FScanThread.Bytes, FScanThread.Items, Phase,
    ScanFraction(FScanThread.Bytes), FScanStart);
  ShowPartial(FScanThread.TakePartial);
  if FScanThread.Finished then
  begin
    FPoll.Enabled := False;
    ScanFinished;
  end;
end;

procedure TMainForm.ScanFinished;
var
  Thread: TScanThread;
  ShowPath: string;
begin
  Thread := FScanThread;
  FScanThread := nil;
  { Finished is set as Execute returns; WaitFor makes its writes (Tree,
    Error) visible to this thread. }
  Thread.WaitFor;
  FDisksBtn.Enabled := True;
  FBackBtn.Enabled := True;
  FRefreshBtn.Enabled := True;
  try
    if Thread.Error <> '' then
    begin
      FScanBar.SetFinished(0, 0, 0);
      ShowAnalysisState('exclamationmark.triangle', 'Scan Failed', Thread.Error,
        ['Rescan'], [@RescanState]);
      Exit;
    end;
    { Replaces the last partial snapshot. }
    FreeAndNil(FTree);
    FTree := Thread.Tree;
    Thread.FTree := nil;
    FMode := umAnalysis;
    { DiskAnalysisView: capacity refreshed when a scan ends. }
    RefreshVolumeCapacity;
    FScanBar.SetFinished(0, 0, (Now - FScanStart) * 86400);
    ShowNode(FRootPath);
    if (Thread.Unreadable > 0) and (FTree.NodeCount <= 1) then
      ShowAnalysisState('lock.slash', 'Couldn''t Read This Location',
        'macOS denied access to this location. Check its permissions, or ' +
        'remove and re-grant it, then rescan.', ['Rescan'], [@RescanState])
    else if FTree.NodeCount <= 1 then
      ShowAnalysisState('folder', 'Nothing to Show',
        'This folder is empty, or nothing in it was large enough to scan.', [], []);
    { Automation: OPENDISK_GUI_SHOW=<folder inside the scan> opens it. }
    ShowPath := GetEnvironmentVariable('OPENDISK_GUI_SHOW');
    if ShowPath <> '' then
    begin
      { Relative values are inside the scan; absolute ones are used as is. }
      if ShowPath[1] <> PathDelim then
        ShowPath := IncludeTrailingPathDelimiter(FRootPath) + ShowPath;
      CrumbNavigate(ResolvePath(ShowPath));
    end;
  finally
    Thread.Free;
  end;
end;

function ResolveNode(Tree: TFileTree; const RootPath, APath: string): TNodeID;
begin
  Result := Tree.NodeIDForPath(APath, RootPath);
end;

{ DiskAnalyzer.swift partial events: show the snapshot, staying in the
  folder being viewed when it exists there yet. }
procedure TMainForm.ShowPartial(Partial: TFileTree);
begin
  if Partial = nil then
    Exit;
  FreeAndNil(FTree);
  FTree := Partial;
  if ResolveNode(FTree, FRootPath, FCurrentPath) = NoNode then
    FCurrentPath := FRootPath;
  ShowNode(FCurrentPath);
end;

procedure TMainForm.ShowNode(const APath: string);
var
  Node: TNodeID;
  NodeName: string;
  Chart: TChartItem;
begin
  if FTree = nil then
    Exit;
  Node := ResolveNode(FTree, FRootPath, APath);
  if Node = NoNode then
    Exit;
  FCurrentPath := APath;
  NodeName := ExtractFileName(ExcludeTrailingPathDelimiter(APath));
  if NodeName = '' then
    NodeName := FRootName;
  Chart := TChartItem.Build(FTree, Node, NodeName, APath);
  FChart.TakeRoot(Chart);
  FCrumbBar.SetPath(FRootPath, FRootName, APath);
  { DiskAnalysisView.swift windowTitle: the folder being shown. }
  Caption := NodeName;
  FListHeader.Caption := 'Largest in ' + NodeName + '  ·  ' +
    FormatFileSize(FTree.SizeOf(Node));
  RefreshList;
  FBackBtn.Enabled := FBreadcrumbs.Count > 0;
  { displayedTotalBytes and rootItems.count. }
  FScanBar.SetTotals(FTree.SizeOf(Node), FList.Items.Count);
end;

{ DiskAnalysisView progressFraction: scanned bytes over the volume's used
  space when scanning a whole disk; unknown (-1) for a folder. }
function TMainForm.ScanFraction(Bytes: Int64): Double;
var
  Used: Int64;
begin
  Used := Int64(FRootTotal) - Int64(FRootFree);
  if (FRootTotal = 0) or (Used <= 0) then
    Exit(-1);
  Result := Min(1, Bytes / Used);
end;

{ DeviceMonitor.volumeCapacity(ofPath:) for the analysed root. }
procedure TMainForm.RefreshVolumeCapacity;
var
  Cap: TVolumeCapacity;
  Available: Int64;
begin
  if VolumeCapacityOf(FRootPath, Cap) and (Cap.TotalBytes > 0) then
  begin
    Available := AvailableBytesOf(Cap);
    FScanBar.SetVolumeCapacity(Cap.TotalBytes, Available,
      Max(0, Available - Cap.FreeBytes));
  end
  else
    FScanBar.ClearVolumeCapacity;
end;

procedure TMainForm.RefreshList;
var
  Node: TNodeID;
  Sorted: TFPList;
  I: Integer;
  Child: TNodeID;
  Line: string;
begin
  FList.Items.BeginUpdate;
  try
    FList.Clear;
    if FTree = nil then
      Exit;
    Node := ResolveNode(FTree, FRootPath, FCurrentPath);
    if Node = NoNode then
      Exit;
    FListMaxSize := 0;
    FListHover := -1;
    Sorted := TFPList.Create;
    try
      FTree.ChildrenSortedForDisplay(Node, Sorted);
      for I := 0 to Sorted.Count - 1 do
      begin
        Child := TNodeID(PtrUInt(Sorted[I]));
        if FTree.SizeOf(Child) <= 0 then
          Continue;
        if FCollector.Contains(FTree.PathOf(Child)) then
          Continue;
        { The name doubles as the accessible text of the owner-drawn row. }
        Line := FTree.NameOf(Child);
        FList.Items.AddObject(Line, TObject(PtrUInt(Child)));
        if FTree.SizeOf(Child) > FListMaxSize then
          FListMaxSize := FTree.SizeOf(Child);
      end;
    finally
      Sorted.Free;
    end;
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TMainForm.RefreshCollector;
begin
  { Deleting and done phases own the bar until they end. }
  if (FDeleteJob <> nil) or FDoneTimer.Enabled then
    Exit;
  FCollectorDetail.Visible := False;
  FDeleteBar.Visible := False;
  FCollectorLabel.Font.Style := [];
  if FCollector.Count = 0 then
  begin
    FCollectorLabel.Caption :=
      'Collector empty — double-click a file to stage deletion.';
    FDeleteButton.Enabled := False;
  end
  else if FCollector.BlockedNotice <> '' then
  begin
    FCollectorLabel.Caption := Format('%s collected · %d item(s) · %s',
      [FormatFileSize(FCollector.TotalBytes), FCollector.Count,
       FCollector.BlockedNotice]);
    FDeleteButton.Enabled := True;
  end
  else
  begin
    FCollectorLabel.Caption := Format('%s collected · %d item(s)',
      [FormatFileSize(FCollector.TotalBytes), FCollector.Count]);
    FDeleteButton.Enabled := True;
  end;
end;

{ FolderRowView.swift: name (medium for folders) over an item count, a 46x4
  size capsule against the largest sibling, the size right-aligned in
  monospaced digits, a chevron for folders; rounded hover / selection. }
procedure TMainForm.ListDrawItem(Control: TWinControl; Index: Integer;
  ARect: TRect; State: TOwnerDrawState);
const
  PadX = 8;
  CapsuleW = 46;
  CapsuleH = 4;
  SizeW = 66;
  ChevronW = 12;
  Gap = 10;
  NameLine = 16;
  { FolderRowView: 22 pt icon, HStack spacing 10. }
  IconSize = 22;
  IconGap = 10;
var
  LB: TListBox;
  C: TCanvas;
  Node: TNodeID;
  IsDir, Selected: Boolean;
  Bg, Ink, Secondary, Tertiary: TColor;
  Row, Cap, Fill: TRect;
  RowName, Detail, SizeText: string;
  Keep: Integer;
  NameTop, Right, SizeLeft, CapLeft, MidY, W, TextLeft: Integer;
  Frac: Double;
begin
  LB := Control as TListBox;
  C := LB.Canvas;
  if (FTree = nil) or (Index < 0) or (Index >= LB.Items.Count) then
    Exit;
  Node := TNodeID(PtrUInt(LB.Items.Objects[Index]));
  IsDir := FTree.IsDirectory(Node);
  Selected := odSelected in State;

  Bg := ColorToRGB(CPanel);
  C.Brush.Style := bsSolid;
  C.Brush.Color := Bg;
  C.FillRect(ARect);

  Row := Rect(ARect.Left + 4, ARect.Top + 2, ARect.Right - 4, ARect.Bottom - 2);
  if Selected or (Index = FListHover) then
  begin
    if Selected then
      C.Brush.Color := ColorToRGB(clHighlight)
    else
    begin
      { Hover: a faint wash of the secondary colour over the panel. }
      Ink := SecondaryTextColor(CPanel);
      C.Brush.Color := RGBToColor(
        (Red(Ink) + 7 * Red(Bg)) div 8,
        (Green(Ink) + 7 * Green(Bg)) div 8,
        (Blue(Ink) + 7 * Blue(Bg)) div 8);
    end;
    C.Pen.Style := psClear;
    C.RoundRect(Row, 16, 16);
    C.Pen.Style := psSolid;
    if Selected then
      Bg := ColorToRGB(clHighlight);
  end;

  if Selected then
    Ink := ColorToRGB(clHighlightText)
  else
    Ink := ColorToRGB(CInk);
  Secondary := SecondaryTextColor(Bg);
  Tertiary := RGBToColor(
    (Red(Secondary) * 2 + Red(Bg)) div 3,
    (Green(Secondary) * 2 + Green(Bg)) div 3,
    (Blue(Secondary) * 2 + Blue(Bg)) div 3);
  if Selected then
  begin
    Secondary := Ink;
    Tertiary := Ink;
  end;

  MidY := (Row.Top + Row.Bottom) div 2;
  Right := Row.Right - PadX;

  { chevron }
  C.Brush.Style := bsClear;
  if IsDir then
  begin
    C.Pen.Color := Tertiary;
    C.Pen.Width := 1;
    C.MoveTo(Right - ChevronW + 4, MidY - 4);
    C.LineTo(Right - ChevronW + 8, MidY);
    C.LineTo(Right - ChevronW + 4, MidY + 4);
  end;
  Right := Right - ChevronW - Gap;

  { size, right-aligned in its fixed column }
  SizeText := FormatFileSize(FTree.SizeOf(Node));
  { System font: CLAUDE.md forbids a monospaced font in the file list, and
    LCL cannot request monospaced digits; the fixed right-aligned column
    keeps sizes from shifting. }
  C.Font.Name := 'default';
  C.Font.Size := 12;
  C.Font.Style := [];
  C.Font.Color := Secondary;
  SizeLeft := Right - SizeW;
  C.TextOut(Right - C.TextWidth(SizeText), MidY - C.TextHeight(SizeText) div 2, SizeText);
  Right := SizeLeft - Gap;

  { size capsule against the largest sibling }
  if FListMaxSize > 0 then
  begin
    Frac := FTree.SizeOf(Node) / FListMaxSize;
    if Frac > 1 then
      Frac := 1;
    CapLeft := Right - CapsuleW;
    Cap := Rect(CapLeft, MidY - CapsuleH div 2, Right, MidY + CapsuleH div 2);
    C.Brush.Style := bsSolid;
    C.Pen.Style := psClear;
    C.Brush.Color := Tertiary;
    C.RoundRect(Cap, CapsuleH, CapsuleH);
    W := Round(CapsuleW * Frac);
    if W < 3 then
      W := 3;
    Fill := Rect(CapLeft, Cap.Top, CapLeft + W, Cap.Bottom);
    C.Brush.Color := Secondary;
    C.RoundRect(Fill, CapsuleH, CapsuleH);
    C.Pen.Style := psSolid;
    Right := CapLeft - Gap;
  end;

  { icon }
  DrawFileIcon(C, Rect(Row.Left + PadX, MidY - IconSize div 2,
    Row.Left + PadX + IconSize, MidY - IconSize div 2 + IconSize),
    FTree.PathOf(Node), IsDir);
  TextLeft := Row.Left + PadX + IconSize + IconGap;

  { name and item count }
  C.Brush.Style := bsClear;
  C.Font.Name := 'default';
  C.Font.Size := 13;
  if IsDir then
    C.Font.Style := [fsBold]
  else
    C.Font.Style := [];
  C.Font.Color := Ink;
  RowName := FTree.NameOf(Node);
  { Too long for the name column: truncate in the middle (CLAUDE.md:
    preserve the start and the extension) rather than clip. }
  Keep := CodePointCount(RowName);
  while (C.TextWidth(RowName) > Right - TextLeft) and (Keep > 6) do
  begin
    Dec(Keep);
    RowName := TruncateMiddle(FTree.NameOf(Node), Keep);
  end;
  Detail := '';
  if IsDir and (FTree.ChildCount(Node) > 0) then
    Detail := Format('%d items', [FTree.ChildCount(Node)]);
  { Fixed metrics: a 13 pt name line, 2 pt spacing, an 11 pt caption
    (FolderRowView VStack spacing 2); canvas TextHeight is not reliable
    before the font is realized. }
  if Detail = '' then
    NameTop := MidY - NameLine div 2
  else
    NameTop := Row.Top + 1;
  { Clip horizontally only: descenders need the space below the line. }
  C.TextRect(Rect(TextLeft, Row.Top, Right, Row.Bottom),
    TextLeft, NameTop, RowName);
  if Detail <> '' then
  begin
    C.Font.Size := 10;
    C.Font.Style := [];
    C.Font.Color := Tertiary;
    C.TextOut(TextLeft, NameTop + NameLine + 2, Detail);
  end;
end;

procedure TMainForm.SetListHover(Index: Integer);
var
  Old: Integer;
  R: TRect;
begin
  if Index = FListHover then
    Exit;
  Old := FListHover;
  FListHover := Index;
  { Repaint only the two rows whose hover state changed. }
  if (Old >= 0) and (Old < FList.Items.Count) then
  begin
    R := FList.ItemRect(Old);
    InvalidateRect(FList.Handle, @R, False);
  end;
  if (Index >= 0) and (Index < FList.Items.Count) then
  begin
    R := FList.ItemRect(Index);
    InvalidateRect(FList.Handle, @R, False);
  end;
end;

procedure TMainForm.ListMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
begin
  SetListHover(FList.ItemAtPos(Point(X, Y), True));
end;

procedure TMainForm.ListMouseLeave(Sender: TObject);
begin
  SetListHover(-1);
end;

procedure TMainForm.CrumbNavigate(const Path: string);
begin
  if (FTree = nil) or (Path = FCurrentPath) then
    Exit;
  { Validate before touching the back stack: ShowNode ignores unknown paths. }
  if ResolveNode(FTree, FRootPath, Path) = NoNode then
    Exit;
  FBreadcrumbs.Add(FCurrentPath);
  ShowNode(Path);
end;

procedure TMainForm.ListDblClick(Sender: TObject);
var
  Child: TNodeID;
  ChildPath: string;
begin
  if (FTree = nil) or (FList.ItemIndex < 0) then
    Exit;
  Child := TNodeID(PtrUInt(FList.Items.Objects[FList.ItemIndex]));
  ChildPath := FTree.PathOf(Child);
  if FTree.IsDirectory(Child) then
  begin
    FBreadcrumbs.Add(FCurrentPath);
    ShowNode(ChildPath);
  end
  else
  begin
    FCollector.Add(ChildPath, FTree.NameOf(Child), FTree.SizeOf(Child), False);
    RefreshCollector;
    RefreshList;
  end;
end;

procedure TMainForm.ChartSelect(Sender: TObject; const APath: string;
  IsCenter: Boolean);
begin
  if IsCenter then
    BackClick(nil)
  else if DirectoryExists(APath) then
  begin
    FBreadcrumbs.Add(FCurrentPath);
    ShowNode(APath);
  end;
end;

procedure TMainForm.CancelScan;
begin
  FPoll.Enabled := False;
  if FScanThread = nil then
    Exit;
  FScanThread.Terminate;
  FScanThread.WaitFor;
  FreeAndNil(FScanThread);
  FBackBtn.Enabled := True;
  FRefreshBtn.Enabled := True;
  FMode := umPicker;
end;

{ DiskAnalysisView.swift requestUnmount / unmount: confirm, then drop the
  scan and return to disk selection (the disk is not ejected). }
procedure TMainForm.DisksClick(Sender: TObject);
begin
  if QuestionDlg('Unmount ' + FRootName + '?',
    'This clears the current scan data and returns to disk selection. ' +
    'It does not eject the disk from macOS.', mtConfirmation,
    { Swift: Unmount is the destructive action, Cancel has the cancel role;
      a destructive confirmation defaults to the safe answer (Return and
      Escape both cancel). }
    [mrOK, 'Unmount', mrCancel, 'Cancel', 'IsDefault', 'IsCancel'], 0) <> mrOK then
    Exit;
  CancelScan;
  FreeAndNil(FTree);
  FChart.Root := nil;
  FList.Clear;
  FBreadcrumbs.Clear;
  FCollector.Clear;
  RefreshCollector;
  ShowPicker;
  RefreshVolumes;
end;

procedure TMainForm.BackClick(Sender: TObject);
var
  Prev: string;
begin
  if FBreadcrumbs.Count = 0 then
    Exit;
  Prev := FBreadcrumbs[FBreadcrumbs.Count - 1];
  FBreadcrumbs.Delete(FBreadcrumbs.Count - 1);
  ShowNode(Prev);
end;

{ DiskAnalysisView.swift refresh(): a new scan rooted at the folder being
  shown, which becomes the scan root. }
procedure TMainForm.RefreshClick(Sender: TObject);
var
  ScanName: string;
begin
  if FCurrentPath = '' then
    Exit;
  if FCurrentPath = FRootPath then
    ScanName := FRootName
  else
    ScanName := ExtractFileName(ExcludeTrailingPathDelimiter(FCurrentPath));
  StartScan(FCurrentPath, ScanName, FRootTotal, FRootFree);
end;

procedure TMainForm.DeleteClick(Sender: TObject);
begin
  if (FCollector.Count = 0) or (FDeleteJob <> nil) then
    Exit;
  if MessageDlg(Format('Permanently delete %d item(s) (%s)? This skips Trash.',
    [FCollector.Count, FormatFileSize(FCollector.TotalBytes)]),
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  { CollectorBar performDeletion: delete in the background, show progress. }
  FDoneTimer.Enabled := False;
  FDeleteButton.Enabled := False;
  FDeleteJob := FCollector.StartDelete;
  FCollectorLabel.Font.Style := [fsBold];
  FCollectorLabel.Caption := 'Deleting…';
  FCollectorDetail.Caption := '';
  FCollectorDetail.Visible := True;
  FDeleteBar.Width := FDeleteButton.Left - FDeleteBar.Left - 24;
  FDeleteBar.Max := Max(1, FCollector.Count);
  FDeleteBar.Position := 0;
  FDeleteBar.Visible := True;
  FDeletePoll.Enabled := True;
end;

procedure TMainForm.DeletePollTick(Sender: TObject);
var
  P: TDeletionProgress;
  Freed: Int64;
  Failed: Integer;
begin
  if FDeleteJob = nil then
  begin
    FDeletePoll.Enabled := False;
    Exit;
  end;
  P := FDeleteJob.Progress;
  if P.CurrentName <> '' then
    FCollectorLabel.Caption := 'Deleting ' + P.CurrentName + '…'
  else
    FCollectorLabel.Caption := 'Deleting…';
  FCollectorDetail.Caption := Format('Freed %s · %d of %d',
    [FormatFileSize(P.FreedBytes), P.Completed, P.Total]);
  FDeleteBar.Max := Max(1, P.Total);
  FDeleteBar.Position := Min(P.Completed, P.Total);
  if not FDeleteJob.Finished then
    Exit;
  FDeletePoll.Enabled := False;
  Freed := FCollector.FinishDelete(FDeleteJob);
  FDeleteJob := nil;
  Failed := FCollector.Failures.Count;
  { Done phase (CollectorBar doneView) for 2 s; the rescan starts now. }
  FDeleteBar.Visible := False;
  FCollectorLabel.Caption := 'Freed ' + FormatFileSize(Freed);
  if Failed > 0 then
    FCollectorDetail.Caption := Format('%d couldn''t be removed', [Failed])
  else
    FCollectorDetail.Caption := '';
  FCollectorDetail.Visible := Failed > 0;
  FDoneTimer.Enabled := True;
  StartScan(FRootPath, FRootName, FRootTotal, FRootFree);
end;

procedure TMainForm.DoneTimerTick(Sender: TObject);
begin
  FDoneTimer.Enabled := False;
  RefreshCollector;
end;

end.
