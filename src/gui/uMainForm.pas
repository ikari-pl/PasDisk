{ Main OpenDisk GUI — volume picker first, then analysis (list + rings).

  Layout mirrors Swift ContentView → DevicePickerView → DiskAnalysisView:
  home screen is disk selection; scanning only starts after a choice. }

unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, ComCtrls, Buttons, Menus, RingsChart, FileTree, Traversal,
  ChartItem, Formatters, Collector, ProtectedPaths, Volumes, PlatformVolumes, PlatformAppearance,
  GuiColors, BreadcrumbBar, TextTrim, EmptyStateView, ScanTopology, ScanStatusBar,
  DisplayList, CleanableSpace, FullDiskAccessUI, SearchController,
  CollectorBarView, PlatformAlert, PlatformFileDrag, RingsLayout,
  PlatformQuickLook, ThinSplitter, PlatformToolbar, PlatformMenus, SkeletonListing,
  PlatformListBatch, PlatformChartAccessibility;

type
  TUIMode = (umPicker, umScanning, umAnalysis);
  TListSortField = (lsName, lsSize);

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

  { DiskAnalyzer.skeletonItems: the root's first level, read off the UI
    thread while the scan starts. }
  TSkeletonThread = class(TThread)
  private
    FPath: string;
  protected
    procedure Execute; override;
  public
    Items: TSkeletonItems;
    constructor Create(const APath: string);
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
    { HSplitView divider; FSplitRatio is the list's share of the width. }
    FSplitter: TThinSplitter;
    FSplitRatio: Double;
    { DiskAnalysisView columnHeader: 'Name' and 'Size', chevron on the
      active column. }
    FListHeader: TPaintBox;
    { Name search (od-31j.18.5): DiskAnalysisView .searchable + SearchResultsView. }
    FSearch: TSearchController;
    FSearchEdit: TEdit;
    FSearchTimer: TTimer;
    FSearchEmpty: TEmptyStateView;
    FSearchQuery: string;
    FSearchItems: TFolderItems;
    FSearchTotal: Integer;
    FSearchPartial: Boolean;
    FSearchRunning: Boolean;
    { The account home, for '~' in search result locations. }
    FHome: string;
    FList: TListBox;
    FSortField: TListSortField;
    FSortAscending: Boolean;
    { Largest size among the listed children (ScanResultsView.swift maxSize)
      and the row under the pointer, -1 for none. }
    FListMaxSize: Int64;
    FListHover: Integer;
    FChartPanel: TPanel;
    FChart: TRingsChart;
    { CollectorBar.swift at the bottom of the chart column (od-31j.18.6). }
    FCollectorBar: TCollectorBarView;
    { FolderRowView / FileActionsMenu context menu (PARITY gaps 14-15). }
    FRowMenu: TPopupMenu;
    FMenuRow: Integer;
    { The file the open context menu acts on (row or ring segment). }
    FMenuItem: TFolderItem;
    { Utilities/FileDrag.swift: the files of the in-app drag in flight,
      whether the chart pane is targeted, and the protected reason. }
    FDragFiles: array of TFolderItem;
    { The skeleton listing shown until the scan's first tree. }
    FSkeletonThread: TSkeletonThread;
    FSkeleton: TSkeletonItems;
    { "Building chart…" in the chart pane while only the skeleton lists. }
    FChartBusy: TEmptyStateView;
    FDropTargeted: Boolean;
    FDragReject: string;
    FRejectTimer, FDragOutTimer: TTimer;
    { CollectorBar deleting / done phases (od-31j.46). }
    FDeleteJob: TDeleteJob;
    FDeletePoll: TTimer;
    FDoneTimer: TTimer;
    FCollector: TCollector;
    FTree: TFileTree;
    FCurrentPath: string;
    FRootPath: string;
    FRootName: string;
    { DiskAnalysisView rootPath / rootName: where the breadcrumbs start.
      FRootPath is the analyzer's scan root, which a refresh or a scan of
      a folder outside the tree moves while the view root stays. }
    FViewRoot, FViewRootName: string;
    FHookStage: Integer;
    FRootTotal: QWord;
    FRootFree: QWord;
    { DiskAnalysisView ScanStatusBar and the scan it describes. }
    FScanBar: TScanStatusBar;
    FScanStart: TDateTime;
    { The 'Purgeable Space' row at the scan root (od-31j.20). }
    FPurgeableTotal: Int64;
    FPurgeableCount: Integer;
    { Entries listed in the Purgeable Space view, in list order: rows show
      the catalogue name and no item count (displayCleanableSpace). }
    FPurgeableEntries: TCleanableEntries;
     FScanThread: TScanThread;
     FPoll: TTimer;
    FBreadcrumbs: TStringList;
    procedure BuildUI;
    procedure ShowPicker;
    procedure ShowAnalysis;
    procedure RefreshVolumes;
    procedure StyleChrome;
    { KeepView: analyzer.scanDirectory within the same analysis — the view
      root, breadcrumbs and collector stay. }
    procedure StartScan(const APath, AName: string; Total, FreeBytes: QWord;
      KeepView: Boolean = False);
    function ShowContentsOf(const Path: string): Boolean;
    procedure NavigateToPath(const Path: string);
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
    procedure ListSelectionChange(Sender: TObject; User: Boolean);
    procedure ListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SortNameClick(Sender: TObject);
    procedure SortSizeClick(Sender: TObject);
    procedure UpdateSortHeader;
    procedure ListHeaderPaint(Sender: TObject);
    procedure ListHeaderMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ApplyListAutomation;
    procedure SortListRows;
    procedure SetListHover(Index: Integer);
    procedure ChartSelect(Sender: TObject; const APath: string; IsCenter: Boolean);
    procedure DisksClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure CollectorRemove(Sender: TObject; const Path: string);
    function RowItem(Index: Integer; out Item: TFolderItem): Boolean;
    procedure StageItems(const Items: array of TFolderItem);
    procedure ListContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure ChartContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure PopUpFileMenu(const Item: TFolderItem; SelectedCount: Integer;
      const ScreenPt: TPoint);
    procedure ChartMenuHookTick(Sender: TObject);
    procedure QuickLookRow(Row: Integer);
    procedure UpdateSubtitle(TotalBytes: Int64);
    procedure ShowSkeleton;
    procedure ToolbarSearch(const Query: string);
    procedure SetUpToolbar;
    procedure AddMenuItem(const ACaption, Symbol: string; Handler: TNotifyEvent;
      ItemEnabled: Boolean = True);
    procedure BodyResize(Sender: TObject);
    procedure SplitterMoved(Sender: TObject);
    procedure SplitterDrag(Sender: TObject; var NewWidth: Integer);
    procedure MenuQuickLookClick(Sender: TObject);
    procedure QuickLookHookTick(Sender: TObject);
    procedure A11yDumpTick(Sender: TObject);
    procedure CollectorRowMenu(Sender: TObject; const Path: string;
      const ScreenPt: TPoint);
    procedure CollectorPreviewClick(Sender: TObject);
    procedure CollectorTerminalClick(Sender: TObject);
    procedure CollectorRemoveClick(Sender: TObject);
    procedure CollectorMenuHookTick(Sender: TObject);
    procedure MenuAddClick(Sender: TObject);
    procedure MenuAddSelectedClick(Sender: TObject);
    procedure MenuShowInFinderClick(Sender: TObject);
    procedure MenuCopyPathClick(Sender: TObject);
    procedure MenuHookTick(Sender: TObject);
    procedure SetUpFileDrag;
    procedure UpdateBarPhase;
    procedure FlagDragProtected;
    function ListDragItem(Row: Integer; out Item: TDragItem): Boolean;
    procedure ListDragBegan(const Rows: array of Integer);
    procedure ChartDragSegment(Sender: TObject; Seg: TRingSegment);
    procedure FileDragEnded(const ScreenPt: TPoint; Accepted: Boolean);
    procedure CollectorDragOut(Sender: TObject; Source: TWinControl;
      const Paths: array of string);
    procedure DragOutEnded(const ScreenPt: TPoint; Accepted: Boolean);
    function InCollectorDropBand(const ScreenPt: TPoint): Boolean;
    function ChartDropUpdate(const ScreenPt: TPoint): Boolean;
    procedure ChartDropExit;
    function ChartDrop(const ScreenPt: TPoint): Boolean;
    function CollectableFiles(const Files: array of TFolderItem): TFolderItems;
    procedure RejectTick(Sender: TObject);
    procedure DragOutTick(Sender: TObject);
    procedure ConfirmHookTick(Sender: TObject);
    procedure DeletePollTick(Sender: TObject);
    procedure DoneTimerTick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormResize(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure StartupPromptTick(Sender: TObject);
    procedure BuildMenus;
    procedure SearchChange(Sender: TObject);
    function RowSizeOf(ID: TNodeID): Int64;
    procedure SearchKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SearchTick(Sender: TObject);
    procedure ClearSearch;
    procedure OpenSearchResult(Index: Integer);
    procedure UpdateSearchEmpty;
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
  LCLType, LCLIntf, Clipbrd, PlatformFS, PlatformLocale, PlatformImages, PlatformFullDiskAccess,
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

const
  { List object of the synthetic 'Purgeable Space' row (never a node). }
  PurgeableRowID = TNodeID(-2);
  { HSplitView minimum widths. }
  ListMinWidth = 320;
  ChartMinWidth = 280;
  { How far above the collector bar a drag still targets it. }
  CollectorDropBand = 64;
  { Search result rows: SearchRowBase - index into FSearchItems. }
  SearchRowBase = TNodeID(-1000);
  { Skeleton rows: SkeletonRowBase - index into FSkeleton; checked before
    the search range, which they lie below. }
  SkeletonRowBase = TNodeID(-10000000);

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

constructor TSkeletonThread.Create(const APath: string);
begin
  FPath := APath;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSkeletonThread.Execute;
begin
  Items := ReadSkeleton(FPath);
end;

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 0);
  Caption := 'OpenDisk';
  { DiskAnalysisView .frame(minWidth: 900, idealWidth: 1100,
    minHeight: 600, idealHeight: 720). }
  Width := 1100;
  Height := 720;
  Constraints.MinWidth := 900;
  Constraints.MinHeight := 600;
  Position := poScreenCenter;
  KeyPreview := True;
  Color := CBg;
  OnDestroy := @FormDestroy;
  OnKeyDown := @FormKeyDown;
  OnResize := @FormResize;
  OnActivate := @FormActivate;
  BuildMenus;
  { OpenDiskApp.checkFullDiskAccessAtStartup: once, 0.5 s after the
    window appears. }
  with TTimer.Create(Self) do
  begin
    Interval := 500;
    OnTimer := @StartupPromptTick;
    Enabled := True;
  end;
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
  SetUpFileDrag;
  SetUpToolbar;
end;

{ DiskAnalysisView .toolbar: the native toolbar replaces the row's
  Unmount, search field and Refresh, leaving the breadcrumb bar
  (BreadcrumbBar above the split; Swift has no back button). Without a
  native toolbar the row keeps them. }
{ A context-menu item with its SF Symbol (Label(_, systemImage:)). }
procedure TMainForm.AddMenuItem(const ACaption, Symbol: string; Handler: TNotifyEvent;
  ItemEnabled: Boolean);
var
  M: TMenuItem;
begin
  M := TMenuItem.Create(FRowMenu);
  M.Caption := ACaption;
  M.Enabled := ItemEnabled;
  M.OnClick := Handler;
  FRowMenu.Items.Add(M);
  if (ACaption <> '-') and (Symbol <> '') then
    SetMenuItemSymbol(M, Symbol);
end;

procedure TMainForm.SetUpToolbar;
var
  H: TToolbarHandlers;
begin
  if not NativeToolbarAvailable then
    Exit;
  FDisksBtn.Visible := False;
  FBackBtn.Visible := False;
  FRefreshBtn.Visible := False;
  FSearchEdit.Visible := False;
  { BreadcrumbBar .padding(.horizontal, 14).padding(.vertical, 7). }
  FNav.Height := 42;
  FCrumbBar.AnchorSideRight.Control := nil;
  FCrumbBar.Anchors := [akLeft, akTop];
  FCrumbBar.SetBounds(14, 7, FNav.ClientWidth - 28, 28);
  FCrumbBar.Anchors := [akLeft, akTop, akRight];
  HandleNeeded;
  H.OnUnmount := @DisksClick;
  H.OnRefresh := @RefreshClick;
  H.OnSearch := @ToolbarSearch;
  InstallWindowToolbar(Self, H);
  ShowWindowToolbar(Self, FMode in [umAnalysis, umScanning]);
end;

procedure TMainForm.BuildUI;
begin
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

  { .searchable(placement: .toolbar, prompt: "Search scanned files and
    folders"). }
  FSearchEdit := TEdit.Create(Self);
  FSearchEdit.Parent := FNav;
  FSearchEdit.TextHint := 'Search scanned files and folders';
  FSearchEdit.Width := 240;
  FSearchEdit.Top := 13;
  FSearchEdit.AnchorSideRight.Control := FRefreshBtn;
  FSearchEdit.AnchorSideRight.Side := asrLeft;
  FSearchEdit.BorderSpacing.Right := 8;
  FSearchEdit.Anchors := [akTop, akRight];
  FSearchEdit.OnChange := @SearchChange;
  FSearchEdit.OnKeyDown := @SearchKeyDown;
  FSearch := TSearchController.Create;
  FHome := ExcludeTrailingPathDelimiter(UserHomePath);
  FSearchTimer := TTimer.Create(Self);
  FSearchTimer.Enabled := False;
  FSearchTimer.Interval := 50;
  FSearchTimer.OnTimer := @SearchTick;

  { The trail fills the space up to the search field and follows resizes. }
  FCrumbBar.AnchorSideRight.Control := FSearchEdit;
  FCrumbBar.AnchorSideRight.Side := asrLeft;
  FCrumbBar.BorderSpacing.Right := 12;
  FCrumbBar.Anchors := [akLeft, akTop, akRight];

  FDeletePoll := TTimer.Create(Self);
  FDeletePoll.Enabled := False;
  FDeletePoll.Interval := 33;
  FDeletePoll.OnTimer := @DeletePollTick;

  FDoneTimer := TTimer.Create(Self);
  FDoneTimer.Enabled := False;
  FDoneTimer.Interval := 2000;
  FDoneTimer.OnTimer := @DoneTimerTick;

  { Spans the window bottom. }
  FScanBar := TScanStatusBar.Create(Self);
  FScanBar.Parent := FAnalysis;
  FScanBar.Align := alBottom;

  FBody := TPanel.Create(Self);
  FBody.Parent := FAnalysis;
  FBody.Align := alClient;
  FBody.BevelOuter := bvNone;
  FBody.Color := CBg;

  FListPanel := TPanel.Create(Self);
  FListPanel.Parent := FBody;
  FListPanel.Align := alLeft;
  { DiskAnalysisView HSplitView: list minWidth 320, ideal 60 %; chart
    minWidth 280, ideal 40 %. }
  FSplitRatio := 0.6;
  FListPanel.Width := Round(Width * FSplitRatio);
  FListPanel.BevelOuter := bvNone;
  FListPanel.Color := CPanel;

  FListHeader := TPaintBox.Create(Self);
  FListHeader.Parent := FListPanel;
  FListHeader.Align := alTop;
  { .caption line + vertical padding 5 + divider. }
  FListHeader.Height := 24;
  FListHeader.OnPaint := @ListHeaderPaint;
  FListHeader.OnMouseUp := @ListHeaderMouseUp;

  FSortField := lsSize;
  FSortAscending := False;

  FList := TListBox.Create(Self);
  FList.Parent := FListPanel;
  FList.Align := alClient;
  FList.BorderStyle := bsNone;
  FList.Color := CPanel;
  FList.Font.Color := CInk;
  FList.Style := lbOwnerDrawFixed;
  FList.MultiSelect := True;
  FList.ExtendedSelect := True;
  FList.ItemHeight := 36;
  FList.OnDrawItem := @ListDrawItem;
  { The accent selection shows focus, as in Swift lists; no extra
    focus rectangle. }
  FList.Options := FList.Options - [lboDrawFocusRect];
  FList.OnMouseMove := @ListMouseMove;
  FList.OnMouseLeave := @ListMouseLeave;
  FList.OnSelectionChange := @ListSelectionChange;
  FList.OnKeyDown := @ListKeyDown;
  FList.OnDblClick := @ListDblClick;
  FList.OnContextPopup := @ListContextPopup;
  FRowMenu := TPopupMenu.Create(Self);

  { SearchResultsView empty states, over the list only. }
  FSearchEmpty := TEmptyStateView.Create(Self);
  FSearchEmpty.Parent := FListPanel;
  FSearchEmpty.Align := alClient;
  FSearchEmpty.Color := CPanel;
  FSearchEmpty.Visible := False;
  FListHover := -1;

  FSplitter := TThinSplitter.Create(Self);
  FSplitter.Parent := FBody;
  FSplitter.Align := alLeft;
  FSplitter.Left := FListPanel.Left + FListPanel.Width;
  FSplitter.Color := CBg;
  FSplitter.Pane := FListPanel;
  FSplitter.OnDrag := @SplitterDrag;
  FSplitter.OnMoved := @SplitterMoved;
  FBody.OnResize := @BodyResize;

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
  FChart.OnContextPopup := @ChartContextPopup;
  { chartPane: ProgressView("Building chart…") while chartRoot is nil. }
  FChartBusy := TEmptyStateView.Create(Self);
  FChartBusy.Parent := FChartPanel;
  FChartBusy.Align := alClient;
  FChartBusy.Color := CBg;
  FChartBusy.Visible := False;

  { DiskAnalysisView chartPane: the CollectorBar under the chart,
    .padding(.horizontal, 12).padding(.bottom, 10); its list and notice
    float over the chart. }
  FCollectorBar := TCollectorBarView.Create(Self);
  FCollectorBar.Parent := FChartPanel;
  FCollectorBar.Align := alBottom;
  FCollectorBar.BorderSpacing.Left := 12;
  FCollectorBar.BorderSpacing.Right := 12;
  FCollectorBar.BorderSpacing.Bottom := 10;
  FCollectorBar.OnDeleteClick := @DeleteClick;
  FCollectorBar.OnRemoveItem := @CollectorRemove;

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

  FPickerTitle.Font.Color := CInk;
  FPickerSub.Font.Color := SecondaryTextColor(CBg);
  FCrumbBar.Color := CPanel;
  FCollectorBar.Invalidate;
  FListHeader.Invalidate;
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
end;

procedure TMainForm.FormResize(Sender: TObject);
begin
  FRefreshBtn.Left := Max(200, Width - FRefreshBtn.Width - 24);
  { DevicePickerView .frame(width: 460): the column does not stretch. }
  FVolList.Width := 460;
  FVolList.Height := Max(200, Height - 260);
  FFolderBtn.Top := FVolList.Top + FVolList.Height + 12;
  FRefreshVolBtn.Top := FFolderBtn.Top;
  FPickerState.BoundsRect := FVolList.BoundsRect;
end;

procedure TMainForm.SearchChange(Sender: TObject);
begin
  { The toolbar field shows the same text (cleared, or set by a hook). }
  if NativeToolbarAvailable and (ToolbarSearchText <> FSearchEdit.Text) then
    SetToolbarSearchText(FSearchEdit.Text);
  FSearchQuery := Trim(FSearchEdit.Text);
  FSearch.SetQuery(FSearchQuery);
  if (FSearchQuery <> '') and not FSearch.HasIndex and (FTree <> nil) then
    FSearch.SetTree(FTree, FScanThread <> nil);
  if FSearchQuery = '' then
  begin
    FSearchItems := nil;
    FSearchTotal := 0;
    FSearchRunning := False;
  end
  else
    FSearchRunning := True;
  FSearchTimer.Enabled := FSearchQuery <> '';
  { onChange(of: searchText): the selection is cleared. }
  FList.ClearSelection;
  RefreshList;
  FListHeader.Invalidate;
end;

procedure TMainForm.SearchKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    ClearSearch;
    Key := 0;
  end
  else if (Key = VK_RETURN) and (FList.Items.Count > 0) then
  begin
    FList.SetFocus;
    if FList.ItemIndex < 0 then
      FList.ItemIndex := 0;
    Key := 0;
  end;
end;

procedure TMainForm.SearchTick(Sender: TObject);
var
  Snap: TSearchSnapshot;
begin
  if FSearch.TakeResults(Snap) and (Snap.Query = FSearchQuery) then
  begin
    FSearchItems := Snap.Items;
    FSearchTotal := Snap.TotalMatches;
    FSearchPartial := Snap.Partial;
    RefreshList;
  end;
  FSearchRunning := FSearch.IsRunning;
  FListHeader.Invalidate;
  UpdateSearchEmpty;
  if not FSearchRunning then
    FSearchTimer.Enabled := False;
end;

procedure TMainForm.ClearSearch;
begin
  if FSearchEdit.Text <> '' then
    FSearchEdit.Text := ''
  else
    SearchChange(nil);
end;

{ DiskAnalysisView.openSearchResult: a folder opens itself, a file its
  parent; the search ends. }
procedure TMainForm.OpenSearchResult(Index: Integer);
var
  Destination: string;
begin
  if (Index < 0) or (Index > High(FSearchItems)) or (FTree = nil) then
    Exit;
  if FSearchItems[Index].IsDirectory then
    Destination := FSearchItems[Index].Path
  else
    Destination := ExtractFileDir(FSearchItems[Index].Path);
  ClearSearch;
  NavigateToPath(Destination);
end;

{ SearchResultsView: 'Searching…' while running with nothing yet,
  ContentUnavailableView.search when nothing matched. }
procedure TMainForm.UpdateSearchEmpty;
begin
  if (FSearchQuery = '') or (FList.Items.Count > 0) then
  begin
    FSearchEmpty.Visible := False;
    Exit;
  end;
  if FSearchRunning then
    FSearchEmpty.SetState('magnifyingglass', 'Searching…', '', [], [])
  else
    FSearchEmpty.SetState('magnifyingglass',
      'No Results for “' + FSearchQuery + '”',
      'Check the spelling or try a new search.', [], []);
  FSearchEmpty.Visible := True;
  FSearchEmpty.BringToFront;
end;

{ The app menu (the first item titled with the Apple logo becomes it on
  macOS): 'Settings…' Cmd-, like SwiftUI's Settings scene. }
procedure TMainForm.BuildMenus;
var
  AppMainMenu: TMainMenu;
  AppMenu, Item: TMenuItem;
begin
  AppMainMenu := TMainMenu.Create(Self);
  AppMenu := TMenuItem.Create(AppMainMenu);
  AppMenu.Caption := #$EF#$A3#$BF;
  AppMainMenu.Items.Add(AppMenu);
  Item := TMenuItem.Create(AppMainMenu);
  Item.Caption := 'Settings…';
  Item.ShortCut := ShortCut(VK_OEM_COMMA, [ssMeta]);
  Item.OnClick := @SettingsClick;
  AppMenu.Add(Item);
  Menu := AppMainMenu;
end;

procedure TMainForm.SettingsClick(Sender: TObject);
begin
  ShowSettingsWindow;
end;

procedure TMainForm.StartupPromptTick(Sender: TObject);
begin
  (Sender as TTimer).Enabled := False;
  { Screenshots: OPENDISK_GUI_SETTINGS=1 opens the Settings window. }
  if GetEnvironmentVariable('OPENDISK_GUI_SETTINGS') = '1' then
  begin
    SettingsClick(nil);
    Exit;
  end;
  { Screenshot automation must not stop at a modal alert. }
  if (GetEnvironmentVariable('OPENDISK_GUI_SCAN') <> '') or
    (GetEnvironmentVariable('OPENDISK_GUI_NO_VOLUMES') <> '') then
    Exit;
  PromptForFullDiskAccessAtStartup;
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
  Caption := 'OpenDisk';
  ShowWindowToolbar(Self, False);
  SetWindowSubtitle(Self, '');
end;

procedure TMainForm.ShowAnalysis;
begin
  FMode := umAnalysis;
  FPicker.Visible := False;
  FAnalysis.Visible := True;
  FAnalysis.BringToFront;
  HideAnalysisState;
  StyleChrome;
  ShowWindowToolbar(Self, True);
end;

{ DiskAnalyzer.scanDirectory: the skeleton fills rootItems while nothing
  else has (same scan, no tree yet); the chart pane says "Building
  chart…" until the first tree. }
procedure TMainForm.ShowSkeleton;
var
  Items: TSkeletonItems;
  Total: Int64;
  I: Integer;
begin
  FSkeletonThread.WaitFor;
  Items := FSkeletonThread.Items;
  FreeAndNil(FSkeletonThread);
  if (FScanThread = nil) or (FTree <> nil) or (Length(Items) = 0) then
    Exit;
  FSkeleton := Items;
  if FAnalysisState.Visible and FAnalysisState.Busy then
  begin
    HideAnalysisState;
    FScanBar.Visible := True;
  end;
  FChartBusy.SetBusy('Building chart…');
  FChartBusy.Visible := True;
  FChartBusy.BringToFront;
  RefreshList;
  Total := 0;
  for I := 0 to High(FSkeleton) do
    Inc(Total, FSkeleton[I].Size);
  { displayedTotalBytes = the skeleton's known sizes. }
  FScanBar.SetTotals(Total, FList.Items.Count);
  UpdateSubtitle(Total);
end;

{ navigationSubtitle: the displayed total, none while it is zero. }
procedure TMainForm.UpdateSubtitle(TotalBytes: Int64);
begin
  if TotalBytes > 0 then
    SetWindowSubtitle(Self, FormatFileSize(TotalBytes))
  else
    SetWindowSubtitle(Self, '');
end;

procedure TMainForm.ToolbarSearch(const Query: string);
begin
  if FSearchEdit.Text <> Query then
    FSearchEdit.Text := Query;
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
    { StorageProgressBar: no outline, fully rounded ends; its colours do
      not change with the row's highlight (the selected-row variant turned
      black on an inactive window's light selection). }
    LB.Canvas.Brush.Style := bsSolid;
    LB.Canvas.Pen.Style := psClear;
    LB.Canvas.Brush.Color := ColorToRGB(CBarTrack);
    LB.Canvas.RoundRect(Bar.Left, Bar.Top, Bar.Right, Bar.Bottom, 6, 6);
    Fill := Bar;
    Fill.Right := Fill.Left + Round((Fill.Right - Fill.Left) * UsedFrac);
    LB.Canvas.Brush.Color := AccentColor(ColorToRGB(CBarFill));
    if Fill.Right > Fill.Left then
      LB.Canvas.RoundRect(Fill.Left, Fill.Top, Fill.Right, Fill.Bottom, 6, 6);
    LB.Canvas.Pen.Style := psSolid;
  end;
  LB.Canvas.Pen.Color := ColorToRGB(SecondaryTextColor(CPanel));
  LB.Canvas.MoveTo(ARect.Right - 18, ARect.Top + 26);
  LB.Canvas.LineTo(ARect.Right - 14, ARect.Top + 30);
  LB.Canvas.LineTo(ARect.Right - 18, ARect.Top + 34);
  { Divider() between the GroupBox rows: the separator colour, inside
    the box's content padding. }
  if Index < LB.Items.Count - 1 then
  begin
    LB.Canvas.Pen.Color := ColorToRGB(clBtnShadow);
    LB.Canvas.Line(ARect.Left + 8, ARect.Bottom - 1, ARect.Right - 8, ARect.Bottom - 1);
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
  FSearch.Free;
  FTree.Free;
  FCollector.Free;
  FBreadcrumbs.Free;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_Z) and (ssMeta in Shift) and (FMode = umAnalysis) then
  begin
    if FCollector.Undo then
    begin
      RefreshCollector;
      { Unstaged items show in the folder list again. }
      RefreshList;
    end;
    Key := 0;
  end
  { handleQuickLookKey: Space without Cmd/Option/Control toggles Quick
    Look, except while typing in the search field. }
  else if (Key = VK_SPACE) and (Shift * [ssMeta, ssAlt, ssCtrl] = []) and
    (FMode = umAnalysis) and not FSearchEdit.Focused and
    not ToolbarSearchFocused(Self) then
  begin
    if QuickLookVisible then
      CloseQuickLook
    else
      QuickLookRow(-1);
    Key := 0;
  end
  else if (Key = VK_OEM_4) and (ssMeta in Shift) and (FMode in [umAnalysis, umScanning]) then
  begin
    DisksClick(nil);
    Key := 0;
  end
  else if (Key = VK_F) and (ssMeta in Shift) and (FMode in [umAnalysis, umScanning]) then
  begin
    if NativeToolbarAvailable then
      FocusToolbarSearch(Self)
    else
    begin
      FSearchEdit.SetFocus;
      FSearchEdit.SelectAll;
    end;
    Key := 0;
  end
  else if (Key = VK_R) and (ssMeta in Shift) and (FMode = umAnalysis) then
  begin
    RefreshClick(nil);
    Key := 0;
  end;
end;

procedure TMainForm.StartScan(const APath, AName: string; Total, FreeBytes: QWord;
  KeepView: Boolean);
var
  Expanded: string;
  RootChanged: Boolean;
begin
  Expanded := ResolvePath(APath);
  RootChanged := not KeepView and (Expanded <> FViewRoot);
  if (IncludeTrailingPathDelimiter(Expanded) = PathDelim) and
    (not FullDiskAccessGranted) then
  begin
    FRootPath := Expanded;
    FRootName := AName;
    FRootTotal := Total;
    FRootFree := FreeBytes;
    if not KeepView then
    begin
      FViewRoot := Expanded;
      FViewRootName := AName;
    end;
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
  if not KeepView then
  begin
    FViewRoot := Expanded;
    FViewRootName := FRootName;
    FBreadcrumbs.Clear;
  end;
  { Swift keeps the collector for the analysed root (failed deletions
    stay staged across the rescan); a different root starts afresh. }
  if RootChanged then
  begin
    FCollector.Clear;
    ClearSearch;
  end;
  RefreshCollector;
  FMode := umScanning;
  ShowAnalysis;
  { DiskAnalysisView: ProgressView("Preparing scan…") while the scan has
    nothing to list yet. }
  FAnalysisState.SetBusy('Preparing scan…');
  FAnalysisState.Visible := True;
  FAnalysisState.BringToFront;
  { ScanStatusBar belongs to the listing branch: none until rows exist. }
  FScanBar.Visible := False;
  FCrumbBar.SetPath(FViewRoot, FViewRootName, Expanded);
  { windowTitle: the view root's name, else the folder's. }
  if Expanded = FViewRoot then
    Caption := FViewRootName
  else
    Caption := FRootName;
  FScanStart := Now;
  FScanBar.SetTotals(0, 0);
  UpdateSubtitle(0);
  FScanBar.SetScanning(0, 0, sspScanning, ScanFraction(0), FScanStart);
  RefreshVolumeCapacity;
  { Disks stays enabled: it cancels the scan. }
  FBackBtn.Enabled := False;
  FRefreshBtn.Enabled := False;
  FSkeleton := nil;
  if FSkeletonThread <> nil then
  begin
    { A previous read is one directory: let it finish. }
    FSkeletonThread.WaitFor;
    FreeAndNil(FSkeletonThread);
  end;
  FSkeletonThread := TSkeletonThread.Create(ResolveDataVolumeAlias(Expanded));
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
  if (FSkeletonThread <> nil) and FSkeletonThread.Finished then
    ShowSkeleton;
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
  StageNames: TStringList;
  DragSample: TDragItem;
  StageSentinel: array of TFolderItem;
  Staged: TNodeID;
  I: Integer;
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
    { DiskAnalyzer: the search index is rebuilt from every final result. }
    FSearch.SetTree(FTree, False);
    if FSearchQuery <> '' then
      FSearchTimer.Enabled := True;
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
    { Automation: OPENDISK_GUI_STAGE=<names> stages those children of the
      root; OPENDISK_GUI_COLLECTOR_LIST=1 keeps the staged list open. }
    if GetEnvironmentVariable('OPENDISK_GUI_STAGE') <> '' then
    begin
      StageNames := TStringList.Create;
      try
        { Names may hold spaces: split on commas only. }
        StageNames.StrictDelimiter := True;
        StageNames.DelimitedText := GetEnvironmentVariable('OPENDISK_GUI_STAGE');
        for I := 0 to StageNames.Count - 1 do
          if StageNames[I] = HiddenSpaceSentinelPath then
          begin
            { The same expansion a Purgeable Space drop uses. }
            SetLength(StageSentinel, 1);
            StageSentinel[0].Path := HiddenSpaceSentinelPath;
            StageItems(CollectableFiles(StageSentinel));
          end
          else
          begin
            Staged := FTree.ChildNamed(RootID, StageNames[I]);
            if Staged <> NoNode then
              FCollector.Add(FTree.PathOf(Staged), FTree.NameOf(Staged),
                FTree.SizeOf(Staged), FTree.IsDirectory(Staged));
          end;
      finally
        StageNames.Free;
      end;
      RefreshCollector;
      RefreshList;
    end;
    FCollectorBar.SetListVisible(GetEnvironmentVariable('OPENDISK_GUI_COLLECTOR_LIST') = '1');
    { Automation: OPENDISK_GUI_CONFIRM_DELETE=1 shows the delete
      confirmation for the staged items (nothing is deleted unless the
      Delete button is clicked). }
    if GetEnvironmentVariable('OPENDISK_GUI_CONFIRM_DELETE') = '1' then
      with TTimer.Create(Self) do
      begin
        Interval := 800;
        OnTimer := @ConfirmHookTick;
        Enabled := True;
      end;
    { Automation: OPENDISK_GUI_DRAG_SELFTEST=<png> prints the drag wiring
      and saves the first row's drag label. }
    if (GetEnvironmentVariable('OPENDISK_GUI_DRAG_SELFTEST') <> '') and
      ListDragItem(0, DragSample) then
      WriteLn('drag self-test: ', FileDragSelfTest(FList, FChartPanel, DragSample,
        GetEnvironmentVariable('OPENDISK_GUI_DRAG_SELFTEST')));
    Flush(Output);
    { Automation: OPENDISK_GUI_CHART_MENU=dx,dy opens the segment menu at that
      offset from the chart centre. }
    if GetEnvironmentVariable('OPENDISK_GUI_CHART_MENU') <> '' then
      with TTimer.Create(Self) do
      begin
        Interval := 800;
        OnTimer := @ChartMenuHookTick;
        Enabled := True;
      end;
    { Automation: OPENDISK_GUI_COLLECTOR_MENU=<index> opens a staged row's menu. }
    if GetEnvironmentVariable('OPENDISK_GUI_COLLECTOR_MENU') <> '' then
      with TTimer.Create(Self) do
      begin
        Interval := 900;
        OnTimer := @CollectorMenuHookTick;
        Enabled := True;
      end;
    { Automation: OPENDISK_GUI_QUICKLOOK=<row> opens Quick Look on that row. }
    if GetEnvironmentVariable('OPENDISK_GUI_QUICKLOOK') <> '' then
      with TTimer.Create(Self) do
      begin
        Interval := 800;
        OnTimer := @QuickLookHookTick;
        Enabled := True;
      end;
    { Automation: OPENDISK_GUI_A11Y_DUMP=1 prints the chart's accessibility. }
    if GetEnvironmentVariable('OPENDISK_GUI_A11Y_DUMP') = '1' then
      with TTimer.Create(Self) do
      begin
        { After a paint: the status bar describes what it drew. }
        Interval := 800;
        OnTimer := @A11yDumpTick;
        Enabled := True;
      end;
    { Automation: OPENDISK_GUI_MENU=<row> opens that row's context menu. }
    if GetEnvironmentVariable('OPENDISK_GUI_MENU') <> '' then
      with TTimer.Create(Self) do
      begin
        Interval := 800;
        OnTimer := @MenuHookTick;
        Enabled := True;
      end;
    { Automation: OPENDISK_GUI_SEARCH=<query> types into the search field. }
    if GetEnvironmentVariable('OPENDISK_GUI_SEARCH') <> '' then
      FSearchEdit.Text := GetEnvironmentVariable('OPENDISK_GUI_SEARCH');
    { Automation: OPENDISK_GUI_SHOW=<folder inside the scan> opens it. }
    ShowPath := GetEnvironmentVariable('OPENDISK_GUI_SHOW');
    { Only for the first scan when a hook chain rescans. }
    if (ShowPath <> '') and (FHookStage = 0) then
    begin
      { Relative values are inside the scan; absolute ones are used as is. }
      if Copy(ShowPath, 1, 2) = '::' then
        ShowNode(ShowPath)
      else
      begin
        if ShowPath[1] <> PathDelim then
          ShowPath := IncludeTrailingPathDelimiter(FRootPath) + ShowPath;
        CrumbNavigate(ResolvePath(ShowPath));
      end;
    end;
    { Automation: OPENDISK_GUI_REFRESH_THEN=<path> refreshes once after the
      first scan (and OPENDISK_GUI_SHOW), then navigates to <path> after the
      refresh — a breadcrumb outside the refreshed tree. }
    if GetEnvironmentVariable('OPENDISK_GUI_REFRESH_THEN') <> '' then
    begin
      Inc(FHookStage);
      if FHookStage = 1 then
        RefreshClick(nil)
      else if FHookStage = 2 then
        NavigateToPath(GetEnvironmentVariable('OPENDISK_GUI_REFRESH_THEN'));
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
  { A query during a scan searches the partial tree until the final one. }
  if (FSearchQuery <> '') and not FSearch.HasIndex then
    FSearch.SetTree(FTree, True);
  if (FCurrentPath <> HiddenSpaceSentinelPath) and
    (ResolveNode(FTree, FRootPath, FCurrentPath) = NoNode) then
    FCurrentPath := FRootPath;
  ShowNode(FCurrentPath);
  { A partial tree may not hold the cache folders yet. }
  if (FCurrentPath = HiddenSpaceSentinelPath) and
    (Length(CleanableCacheEntriesOf(FTree, FRootPath)) = 0) then
  begin
    FCurrentPath := FRootPath;
    ShowNode(FCurrentPath);
  end;
end;

procedure TMainForm.ShowNode(const APath: string);
var
  Node: TNodeID;
  NodeName: string;
  Chart: TChartItem;
  Entries: TCleanableEntries;
  Leaves: TChartLeaves;
  I: Integer;
begin
  if FTree = nil then
    Exit;
  { The first tree replaces the skeleton and "Building chart…". }
  FSkeleton := nil;
  if FChartBusy.Visible then
  begin
    FChartBusy.SetState('', '', '', [], []);
    FChartBusy.Visible := False;
  end;
  { The first rows replace "Preparing scan…". }
  if FAnalysisState.Visible and FAnalysisState.Busy then
  begin
    HideAnalysisState;
    FScanBar.Visible := True;
  end;
  if APath = HiddenSpaceSentinelPath then
  begin
    { DiskAnalyzer.navigateToPath(sentinel) / displayCleanableSpace. }
    Entries := SortedForDisplay(CleanableCacheEntriesOf(FTree, FRootPath));
    if Length(Entries) = 0 then
      Exit;
    FCurrentPath := APath;
    SetLength(Leaves, Length(Entries));
    for I := 0 to High(Entries) do
    begin
      Leaves[I].Name := Entries[I].Name;
      Leaves[I].Path := Entries[I].Path;
      Leaves[I].Size := Entries[I].Size;
      Leaves[I].IsDirectory := True;
    end;
    FChart.TakeRoot(TChartItem.BuildSynthetic(HiddenSpaceFolderName,
      HiddenSpaceSentinelPath, Leaves));
    FCrumbBar.SetPath(FViewRoot, FViewRootName, APath);
    { windowTitle drops the '::'. }
    Caption := HiddenSpaceFolderName;
    RefreshList;
    UpdateSortHeader;
    FBackBtn.Enabled := FBreadcrumbs.Count > 0;
    FScanBar.SetTotals(CleanableTotal(Entries), FList.Items.Count);
    UpdateSubtitle(CleanableTotal(Entries));
    Exit;
  end;
  Node := ResolveNode(FTree, FRootPath, APath);
  if Node = NoNode then
    Exit;
  FCurrentPath := APath;
  NodeName := ExtractFileName(ExcludeTrailingPathDelimiter(APath));
  if APath = FViewRoot then
    NodeName := FViewRootName
  else if NodeName = '' then
    NodeName := FRootName;
  Chart := TChartItem.Build(FTree, Node, NodeName, APath);
  FChart.TakeRoot(Chart);
  FCrumbBar.SetPath(FViewRoot, FViewRootName, APath);
  { DiskAnalysisView.swift windowTitle: the folder being shown. }
  Caption := NodeName;
  RefreshList;
  UpdateSortHeader;
  FBackBtn.Enabled := FBreadcrumbs.Count > 0;
  { displayedTotalBytes and rootItems.count. }
  FScanBar.SetTotals(FTree.SizeOf(Node), FList.Items.Count);
  UpdateSubtitle(FTree.SizeOf(Node));
end;

procedure TMainForm.UpdateSortHeader;
begin
  FListHeader.Invalidate;
end;

const
  { columnHeader: leading 40 (the row text after the icon), trailing 20;
    the size column ends where the rows' size text ends. }
  HeaderNameX = 38;
  HeaderSizeRight = 38;
  HeaderChevron = 8;

{ x where the Size label (with its chevron) starts in the header. }
function SizeHeaderLeft(Canvas: TCanvas; Width: Integer): Integer;
begin
  Result := Width - HeaderSizeRight - Canvas.TextWidth('Size') - 3 - HeaderChevron;
end;

{ Int.formatted(): thousands grouped with the locale separator. }
function GroupedCount(N: Integer): string;
var
  Dec_, Group: string;
  Digits: string;
  I, K: Integer;
begin
  NumberSeparators(Dec_, Group);
  Digits := IntToStr(N);
  Result := '';
  K := 0;
  for I := Length(Digits) downto 1 do
  begin
    if (K > 0) and (K mod 3 = 0) then
      Result := Group + Result;
    Result := Digits[I] + Result;
    Inc(K);
  end;
end;

procedure TMainForm.ListHeaderPaint(Sender: TObject);
var
  C: TCanvas;
  Bg, Ink: TColor;
  Glyph: TBitmap;
  X, Y: Integer;
  Summary: string;

  procedure DrawColumn(const Text: string; AtX: Integer; Active: Boolean);
  begin
    C.TextOut(AtX, Y, Text);
    if not Active then
      Exit;
    { chevron.up when ascending, chevron.down when descending, 8 pt bold. }
    if FSortAscending then
      Glyph := SystemSymbolBitmap('chevron.up', 2 * HeaderChevron, Ink)
    else
      Glyph := SystemSymbolBitmap('chevron.down', 2 * HeaderChevron, Ink);
    if Glyph <> nil then
    try
      X := AtX + C.TextWidth(Text) + 3;
      C.StretchDraw(Rect(X, Y + 3, X + HeaderChevron, Y + 3 + HeaderChevron), Glyph);
    finally
      Glyph.Free;
    end;
  end;

begin
  C := FListHeader.Canvas;
  Bg := ColorToRGB(CPanel);
  Ink := SecondaryTextColor(Bg);
  C.Brush.Style := bsSolid;
  C.Brush.Color := Bg;
  C.FillRect(FListHeader.ClientRect);
  C.Pen.Color := ColorToRGB(clBtnShadow);
  C.Line(0, FListHeader.Height - 1, FListHeader.Width, FListHeader.Height - 1);
  C.Brush.Style := bsClear;
  C.Font.Size := 10;
  C.Font.Style := [fsBold];
  C.Font.Color := Ink;
  Y := (FListHeader.Height - 1 - C.TextHeight('Ag')) div 2;
  if FSearchQuery <> '' then
  begin
    { SearchResultsView header: summary, partial note, spinner. }
    C.Font.Style := [];
    if Length(FSearchItems) = 0 then
      Exit;
    if FSearchTotal > Length(FSearchItems) then
      Summary := Format('Largest %d of %s matches', [Length(FSearchItems),
        GroupedCount(FSearchTotal)])
    else if FSearchTotal = 1 then
      Summary := '1 match · largest first'
    else
      Summary := GroupedCount(FSearchTotal) + ' matches · largest first';
    C.TextOut(12, Y, Summary);
    if FSearchPartial then
    begin
      C.Font.Color := RGBToColor((Red(Ink) + Red(Bg)) div 2,
        (Green(Ink) + Green(Bg)) div 2, (Blue(Ink) + Blue(Bg)) div 2);
      C.TextOut(12 + C.TextWidth(Summary) + 6, Y,
        '· scan in progress, results may be incomplete');
    end;
    Exit;
  end;
  DrawColumn('Name', HeaderNameX, FSortField = lsName);
  DrawColumn('Size', SizeHeaderLeft(C, FListHeader.Width), FSortField = lsSize);
end;

procedure TMainForm.ListHeaderMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  SizeLeft: Integer;
begin
  if (Button <> mbLeft) or (FSearchQuery <> '') then
    Exit;
  FListHeader.Canvas.Font.Size := 10;
  FListHeader.Canvas.Font.Style := [fsBold];
  SizeLeft := SizeHeaderLeft(FListHeader.Canvas, FListHeader.Width);
  if X >= SizeLeft - 8 then
    SortSizeClick(Sender)
  else if (X >= HeaderNameX - 8) and
    (X <= HeaderNameX + FListHeader.Canvas.TextWidth('Name') + 3 + HeaderChevron + 8) then
    SortNameClick(Sender);
end;

procedure TMainForm.SortNameClick(Sender: TObject);
begin
  if FSortField = lsName then FSortAscending := not FSortAscending
  else begin FSortField := lsName; FSortAscending := True; end;
  RefreshList;
  UpdateSortHeader;
end;

procedure TMainForm.SortSizeClick(Sender: TObject);
begin
  if FSortField = lsSize then FSortAscending := not FSortAscending
  else begin FSortField := lsSize; FSortAscending := False; end;
  RefreshList;
  UpdateSortHeader;
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
  Node, Child: TNodeID;
  Listed: TNodeIDArray;
  Entries: TCleanableEntries;
  I, InsertAt: Integer;
  AllCollected: Boolean;

  procedure AddRow(ID: TNodeID; const Name: string; Size: Int64);
  begin
    { The name doubles as the accessible text of the owner-drawn row. }
    FList.Items.AddObject(Name, TObject(PtrInt(ID)));
    if Size > FListMaxSize then
      FListMaxSize := Size;
  end;

begin
  { One table reload for the whole refill, not one per row. }
  BeginListBatch(FList);
  FList.Items.BeginUpdate;
  try
    FList.Clear;
    FListMaxSize := 0;
    FListHover := -1;
    FPurgeableTotal := 0;
    FPurgeableCount := 0;
    FPurgeableEntries := nil;
    if FSearchQuery <> '' then
    begin
      { DiskAnalysisView visibleItems in search mode: results minus the
        collected ones, then the user's sort. }
      for I := 0 to High(FSearchItems) do
        if not FCollector.Contains(FSearchItems[I].Path) then
          AddRow(SearchRowBase - I, FSearchItems[I].Name, FSearchItems[I].Size);
      SortListRows;
      UpdateSearchEmpty;
      Exit;
    end;
    UpdateSearchEmpty;
    if (FTree = nil) and (FSkeleton <> nil) then
    begin
      for I := 0 to High(FSkeleton) do
        if not FCollector.Contains(FSkeleton[I].Path) then
          AddRow(SkeletonRowBase - I, FSkeleton[I].Name, FSkeleton[I].Size);
      SortListRows;
      Exit;
    end;
    if FTree = nil then
      Exit;
    if FCurrentPath = HiddenSpaceSentinelPath then
    begin
      { displayCleanableSpace: the cache folders, largest first. }
      Entries := SortedForDisplay(CleanableCacheEntriesOf(FTree, FRootPath));
      for I := 0 to High(Entries) do
      begin
        Child := FTree.NodeIDForPath(Entries[I].Path, FRootPath);
        if (Child <> NoNode) and not FCollector.Contains(Entries[I].Path) then
        begin
          AddRow(Child, Entries[I].Name, Entries[I].Size);
          SetLength(FPurgeableEntries, Length(FPurgeableEntries) + 1);
          FPurgeableEntries[High(FPurgeableEntries)] := Entries[I];
        end;
      end;
      Exit;
    end;
    Node := ResolveNode(FTree, FRootPath, FCurrentPath);
    if Node = NoNode then
      Exit;
    { DiskAnalyzer.swift folderItems: top 100 below the scan root, only
      items above 1 KiB once the scan is complete. }
    Listed := VisibleChildren(FTree, Node, Node = RootID, FScanThread <> nil);
    for I := 0 to High(Listed) do
    begin
      Child := Listed[I];
      if FCollector.Contains(FTree.PathOf(Child)) then
        Continue;
      AddRow(Child, FTree.NameOf(Child), FTree.SizeOf(Child));
    end;
    { display(node:) adds the summary row at the scan root; visibleItems
      hides it once every entry is collected; it sorts by size. }
    if Node = RootID then
    begin
      Entries := CleanableCacheEntriesOf(FTree, FRootPath);
      AllCollected := True;
      for I := 0 to High(Entries) do
        if not FCollector.Contains(Entries[I].Path) then
          AllCollected := False;
      FPurgeableTotal := CleanableTotal(Entries);
      FPurgeableCount := Length(Entries);
      if (FPurgeableTotal > 0) and not AllCollected then
      begin
        InsertAt := 0;
        while (InsertAt < FList.Items.Count) and
          (FTree.SizeOf(TNodeID(PtrUInt(FList.Items.Objects[InsertAt]))) >= FPurgeableTotal) do
          Inc(InsertAt);
        FList.Items.InsertObject(InsertAt, HiddenSpaceFolderName,
          TObject(PtrInt(PurgeableRowID)));
        if FPurgeableTotal > FListMaxSize then
          FListMaxSize := FPurgeableTotal;
      end;
    end;
    SortListRows;
    ApplyListAutomation;
  finally
    FList.Items.EndUpdate;
    EndListBatch(FList);
  end;
end;

function TMainForm.RowSizeOf(ID: TNodeID): Int64;
begin
  if ID = PurgeableRowID then
    Result := FPurgeableTotal
  else if ID <= SkeletonRowBase then
    Result := FSkeleton[SkeletonRowBase - ID].Size
  else if ID <= SearchRowBase then
    Result := FSearchItems[SearchRowBase - ID].Size
  else
    Result := FTree.SizeOf(ID);
end;

type
  TSortRow = record
    ID: TNodeID;
    Name: string;
    Size: Int64;
  end;
  TSortRows = array of TSortRow;

{ DiskAnalysisView visibleItems sorted by the header: rows are read once,
  merge-sorted (stable, O(n log n)) and written back in one update. }
procedure TMainForm.SortListRows;
var
  Rows, Scratch: TSortRows;
  I, N: Integer;

  function Before(const A, B: TSortRow): Boolean;
  var
    Comparison: Integer;
  begin
    if FSortField = lsName then
      Comparison := CompareText(A.Name, B.Name)
    else if A.Size < B.Size then
      Comparison := -1
    else if A.Size > B.Size then
      Comparison := 1
    else
      Comparison := 0;
    if FSortAscending then
      Result := Comparison < 0
    else
      Result := Comparison > 0;
  end;

  procedure MergeSort(Lo, Hi: Integer);
  var
    Mid, L, R, K: Integer;
  begin
    if Hi - Lo < 1 then
      Exit;
    Mid := (Lo + Hi) div 2;
    MergeSort(Lo, Mid);
    MergeSort(Mid + 1, Hi);
    L := Lo;
    R := Mid + 1;
    K := Lo;
    while (L <= Mid) and (R <= Hi) do
    begin
      { Equal rows keep their order. }
      if Before(Rows[R], Rows[L]) then
      begin
        Scratch[K] := Rows[R];
        Inc(R);
      end
      else
      begin
        Scratch[K] := Rows[L];
        Inc(L);
      end;
      Inc(K);
    end;
    while L <= Mid do
    begin
      Scratch[K] := Rows[L];
      Inc(L);
      Inc(K);
    end;
    while R <= Hi do
    begin
      Scratch[K] := Rows[R];
      Inc(R);
      Inc(K);
    end;
    for K := Lo to Hi do
      Rows[K] := Scratch[K];
  end;

begin
  N := FList.Items.Count;
  if N < 2 then
    Exit;
  SetLength(Rows, N);
  SetLength(Scratch, N);
  for I := 0 to N - 1 do
  begin
    Rows[I].ID := TNodeID(PtrInt(FList.Items.Objects[I]));
    Rows[I].Name := FList.Items[I];
    Rows[I].Size := RowSizeOf(Rows[I].ID);
  end;
  MergeSort(0, N - 1);
  BeginListBatch(FList);
  FList.Items.BeginUpdate;
  try
    for I := 0 to N - 1 do
    begin
      FList.Items[I] := Rows[I].Name;
      FList.Items.Objects[I] := TObject(PtrInt(Rows[I].ID));
    end;
  finally
    FList.Items.EndUpdate;
    EndListBatch(FList);
  end;
end;

{ The table selects natively (click, Shift range, Cmd toggle, and a
  press on a selected row keeps the selection so it can be dragged); the
  synthetic row is never part of a selection. }
procedure TMainForm.ListSelectionChange(Sender: TObject; User: Boolean);
var
  I: Integer;
begin
  for I := 0 to FList.Items.Count - 1 do
    if FList.Selected[I] and
      (TNodeID(PtrInt(FList.Items.Objects[I])) = PurgeableRowID) then
      FList.Selected[I] := False;
  FList.Invalidate;
end;

procedure TMainForm.ListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    ListDblClick(Sender);
  end;
end;

procedure TMainForm.ApplyListAutomation;
var
  Value, Field, Direction, Names: string;
  P, I, Start, Stop: Integer;
begin
  Value := GetEnvironmentVariable('OPENDISK_GUI_SORT');
  if Value <> '' then
  begin
    P := Pos(',', Value);
    if P > 0 then begin Field := Copy(Value, 1, P - 1); Direction := Copy(Value, P + 1, MaxInt); end
    else begin Field := Value; Direction := ''; end;
    if LowerCase(Field) = 'name' then FSortField := lsName else if LowerCase(Field) = 'size' then FSortField := lsSize;
    if LowerCase(Direction) = 'asc' then
      FSortAscending := True
    else if LowerCase(Direction) = 'desc' then
      FSortAscending := False
    else
      FSortAscending := FSortField = lsName;
    SortListRows;
    UpdateSortHeader;
  end;
  Names := GetEnvironmentVariable('OPENDISK_GUI_SELECT');
  if Names = '' then Exit;
  FList.ClearSelection;
  Start := 1;
  while Start <= Length(Names) do
  begin
    P := Pos(',', Copy(Names, Start, MaxInt));
    if P = 0 then Stop := Length(Names) + 1 else Stop := Start + P - 1;
    for I := 0 to FList.Items.Count - 1 do
      if (CompareText(FList.Items[I], Copy(Names, Start, Stop - Start)) = 0) and
        (TNodeID(PtrInt(FList.Items.Objects[I])) <> PurgeableRowID) then
        FList.Selected[I] := True;
    Start := Stop + 1;
  end;
end;

procedure TMainForm.RefreshCollector;
var
  Items: TCollectorItems;
  I: Integer;
  F: TCollectedFile;
begin
  SetLength(Items, FCollector.Count);
  for I := 0 to FCollector.Count - 1 do
  begin
    F := TCollectedFile(FCollector.Items[I]);
    Items[I].Name := F.Name;
    Items[I].Path := F.Path;
    Items[I].Size := F.Size;
    Items[I].IsDirectory := F.IsDirectory;
  end;
  FCollectorBar.SetItems(Items);
  { Deleting and done phases own the footer until they end. }
  UpdateBarPhase;
end;

{ CollectorBar phase outside deletion: the protected-drag rejection, the
  drop target (not while dragging out), or idle. }
procedure TMainForm.UpdateBarPhase;
begin
  if (FDeleteJob <> nil) or FDoneTimer.Enabled then
    Exit;
  if FDragReject <> '' then
    FCollectorBar.SetPhase(cbRejecting, FDragReject)
  else if FDropTargeted and not FCollector.IsDraggingOut then
    FCollectorBar.SetPhase(cbTargeted)
  else
    FCollectorBar.SetPhase(cbIdle);
end;

procedure TMainForm.SetUpFileDrag;
begin
  FRejectTimer := TTimer.Create(Self);
  FRejectTimer.Enabled := False;
  { flagDraggedProtected: the rejection clears itself after 4 s. }
  FRejectTimer.Interval := 4000;
  FRejectTimer.OnTimer := @RejectTick;
  FDragOutTimer := TTimer.Create(Self);
  FDragOutTimer.Enabled := False;
  { endDragOut: a drop another app took ends the drag-out after 2 s. }
  FDragOutTimer.Interval := 2000;
  FDragOutTimer.OnTimer := @DragOutTick;
  FChart.OnDragSegment := @ChartDragSegment;
  FCollectorBar.OnDragOut := @CollectorDragOut;
  FCollectorBar.OnRowMenu := @CollectorRowMenu;
  FList.HandleNeeded;
  EnableListRowDrag(FList, @ListDragItem, @ListDragBegan, @FileDragEnded);
  FChartPanel.HandleNeeded;
  RegisterDropZone(FChartPanel, @ChartDropUpdate, @ChartDropExit, @ChartDrop);
end;

{ FolderRowView.draggedProtectedReason / RingsChartView.protectedReason. }
procedure TMainForm.FlagDragProtected;
var
  I: Integer;
  Reason: string;
begin
  FDragReject := '';
  for I := 0 to High(FDragFiles) do
  begin
    Reason := ProtectedReason(FDragFiles[I].Path);
    if Reason <> '' then
    begin
      FDragReject := '“' + FDragFiles[I].Name + '” ' + Reason;
      Break;
    end;
  end;
  FRejectTimer.Enabled := False;
  FRejectTimer.Enabled := FDragReject <> '';
  UpdateBarPhase;
end;

procedure TMainForm.RejectTick(Sender: TObject);
begin
  FRejectTimer.Enabled := False;
  FDragReject := '';
  UpdateBarPhase;
end;

{ FolderRowView: rows drag as files; of the synthetic rows only Purgeable
  Space drags (in-app only, expanded on drop). }
function TMainForm.ListDragItem(Row: Integer; out Item: TDragItem): Boolean;
var
  F: TFolderItem;
begin
  Result := RowItem(Row, F) and
    ((Copy(F.Path, 1, 2) <> '::') or (F.Path = HiddenSpaceSentinelPath));
  if not Result then
    Exit;
  Item.Path := F.Path;
  Item.Name := F.Name;
  Item.Size := F.Size;
  Item.IsDirectory := F.IsDirectory;
end;

procedure TMainForm.ListDragBegan(const Rows: array of Integer);
var
  I: Integer;
  F: TFolderItem;
begin
  FDragFiles := nil;
  for I := 0 to High(Rows) do
    if RowItem(Rows[I], F) and
      ((Copy(F.Path, 1, 2) <> '::') or (F.Path = HiddenSpaceSentinelPath)) then
    begin
      SetLength(FDragFiles, Length(FDragFiles) + 1);
      FDragFiles[High(FDragFiles)] := F;
    end;
  FlagDragProtected;
end;

procedure TMainForm.ChartDragSegment(Sender: TObject; Seg: TRingSegment);
var
  Items: TDragItems;
begin
  SetLength(FDragFiles, 1);
  FDragFiles[0].Path := Seg.Path;
  FDragFiles[0].Name := Seg.Name;
  FDragFiles[0].Size := Seg.Size;
  FDragFiles[0].IsDirectory := Seg.Kind = ckDirectory;
  FDragFiles[0].ItemCount := 0;
  SetLength(Items, 1);
  Items[0].Path := Seg.Path;
  Items[0].Name := Seg.Name;
  Items[0].Size := Seg.Size;
  Items[0].IsDirectory := Seg.Kind = ckDirectory;
  FlagDragProtected;
  if not BeginFileDrag(FChart, Items, True, @FileDragEnded) then
    FileDragEnded(Point(0, 0), False);
end;

{ onEnd: flagDraggedProtected(nil). FileDragSource.filesMovedNotification:
  another app took the drop and a dragged file is gone (moved), so the
  view refreshes. }
procedure TMainForm.FileDragEnded(const ScreenPt: TPoint; Accepted: Boolean);
var
  I: Integer;
  Moved: Boolean;
begin
  Moved := False;
  if Accepted then
    for I := 0 to High(FDragFiles) do
      if (Copy(FDragFiles[I].Path, 1, 2) <> '::') and
        not FileExists(FDragFiles[I].Path) and not DirectoryExists(FDragFiles[I].Path) then
        Moved := True;
  FChart.DragFinished;
  FDragFiles := nil;
  FDropTargeted := False;
  FRejectTimer.Enabled := False;
  FDragReject := '';
  UpdateBarPhase;
  if Moved then
    RefreshClick(nil);
end;

{ CollectedRow / footer fileDrag(exportsFileURLs: false): beginDragOut. }
procedure TMainForm.CollectorDragOut(Sender: TObject; Source: TWinControl;
  const Paths: array of string);
var
  Items: TDragItems;
  I, Idx: Integer;
  F: TCollectedFile;
begin
  FDragOutTimer.Enabled := False;
  FCollector.BeginDragOut(Paths);
  Items := nil;
  for I := 0 to High(Paths) do
    for Idx := 0 to FCollector.Count - 1 do
    begin
      F := TCollectedFile(FCollector.Items[Idx]);
      if F.Path = Paths[I] then
      begin
        SetLength(Items, Length(Items) + 1);
        Items[High(Items)].Path := F.Path;
        Items[High(Items)].Name := F.Name;
        Items[High(Items)].Size := F.Size;
        Items[High(Items)].IsDirectory := F.IsDirectory;
      end;
    end;
  FCollectorBar.SetDraggingOut(True);
  if not BeginFileDrag(Source, Items, False, @DragOutEnded) then
  begin
    FCollector.CancelDragOut;
    FCollectorBar.SetDraggingOut(False);
    FCollectorBar.DragFinished;
  end;
end;

procedure TMainForm.DragOutEnded(const ScreenPt: TPoint; Accepted: Boolean);
begin
  FCollectorBar.DragFinished;
  FDropTargeted := False;
  FCollector.EndDragOut(Accepted);
  { Still pending: another app took the drop; it ends in 2 s. }
  FDragOutTimer.Enabled := FCollector.IsDraggingOut;
  FCollectorBar.SetDraggingOut(FCollector.IsDraggingOut);
  RefreshCollector;
  RefreshList;
end;

procedure TMainForm.DragOutTick(Sender: TObject);
begin
  FDragOutTimer.Enabled := False;
  FCollector.CancelDragOut;
  FCollectorBar.SetDraggingOut(False);
  UpdateBarPhase;
end;

{ InAppFileDropDelegate.dropEntered / dropUpdated. Swift takes drops
  anywhere in the chart pane; here (ikari's call, 2026-10-06) only near
  the collector: the bar, its list, or the band just above the bar, so
  passing over the chart does not arm the drop. }
function TMainForm.InCollectorDropBand(const ScreenPt: TPoint): Boolean;
var
  P: TPoint;
begin
  P := FChartPanel.ScreenToClient(ScreenPt);
  Result := FCollectorBar.InKeepZone(ScreenPt) or
    ((P.Y >= FCollectorBar.Top - CollectorDropBand) and (P.Y <= FCollectorBar.Top) and
     (P.X >= FCollectorBar.Left) and (P.X <= FCollectorBar.Left + FCollectorBar.Width));
end;

function TMainForm.ChartDropUpdate(const ScreenPt: TPoint): Boolean;
var
  Inside: Boolean;
begin
  { A drag-out may be released anywhere in the pane: outside the keep
    zones it unstages. }
  if FCollector.IsDraggingOut then
    Exit(True);
  Inside := InCollectorDropBand(ScreenPt);
  Result := Inside;
  if Inside <> FDropTargeted then
  begin
    FDropTargeted := Inside;
    UpdateBarPhase;
  end;
end;

procedure TMainForm.ChartDropExit;
begin
  if FDropTargeted then
  begin
    FDropTargeted := False;
    UpdateBarPhase;
  end;
end;

{ handleCollectorDrop's expansion: the Purgeable Space sentinel becomes
  its cache folders (analyzer.collectablePurgeableFiles), and protected
  paths are left out. }
function TMainForm.CollectableFiles(const Files: array of TFolderItem): TFolderItems;
var
  I, J: Integer;
  Entries: TCleanableEntries;

  procedure Keep(const Path, Name: string; Size: Int64; IsDirectory: Boolean);
  begin
    if IsProtectedPath(Path) then
      Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Path := Path;
    Result[High(Result)].Name := Name;
    Result[High(Result)].Size := Size;
    Result[High(Result)].IsDirectory := IsDirectory;
    Result[High(Result)].ItemCount := 0;
  end;

begin
  Result := nil;
  for I := 0 to High(Files) do
    if Files[I].Path = HiddenSpaceSentinelPath then
    begin
      Entries := CleanableCacheEntriesOf(FTree, FRootPath);
      for J := 0 to High(Entries) do
        Keep(Entries[J].Path, Entries[J].Name, Entries[J].Size, True);
    end
    else
      Keep(Files[I].Path, Files[I].Name, Files[I].Size, Files[I].IsDirectory);
end;

{ DiskAnalysisView.handleCollectorDrop. }
function TMainForm.ChartDrop(const ScreenPt: TPoint): Boolean;
var
  Allowed: array of TFolderItem;

begin
  Result := True;
  if FCollector.IsDraggingOut then
  begin
    FCollector.ResolveDragOut(FCollectorBar.InKeepZone(ScreenPt));
    FCollectorBar.SetDraggingOut(False);
    RefreshCollector;
    RefreshList;
    Exit;
  end;
  if not InCollectorDropBand(ScreenPt) then
    Exit(False);
  FRejectTimer.Enabled := False;
  FDragReject := '';
  Allowed := CollectableFiles(FDragFiles);
  Result := Length(Allowed) > 0;
  if Result then
    StageItems(Allowed)
  else
    UpdateBarPhase;
end;

{ The real item behind a list row (folder node or search result); False
  for synthetic rows. }
function TMainForm.RowItem(Index: Integer; out Item: TFolderItem): Boolean;
var
  ID: TNodeID;
begin
  Result := False;
  if (Index < 0) or (Index >= FList.Items.Count) then
    Exit;
  ID := TNodeID(PtrUInt(FList.Items.Objects[Index]));
  if ID <= SkeletonRowBase then
    with FSkeleton[SkeletonRowBase - ID] do
    begin
      Item.Name := Name;
      Item.Path := Path;
      Item.Size := Size;
      Item.IsDirectory := IsDirectory;
      Item.ItemCount := 0;
    end
  else if ID <= SearchRowBase then
    Item := FSearchItems[SearchRowBase - ID]
  else if ID = PurgeableRowID then
  begin
    { The HiddenSpaceInfo sentinel: not a path, collected as its folders. }
    Item.Name := HiddenSpaceFolderName;
    Item.Path := HiddenSpaceSentinelPath;
    Item.Size := FPurgeableTotal;
    Item.IsDirectory := True;
    Item.ItemCount := FPurgeableCount;
  end
  else if (ID >= 0) and (FTree <> nil) then
  begin
    Item.Name := FTree.NameOf(ID);
    Item.Path := FTree.PathOf(ID);
    Item.Size := FTree.SizeOf(ID);
    Item.IsDirectory := FTree.IsDirectory(ID);
    Item.ItemCount := 0;
  end
  else
    Exit;
  Result := True;
end;

{ collector.add(files): protected paths are refused with a notice. }
procedure TMainForm.StageItems(const Items: array of TFolderItem);
var
  Files: array of TCollectedEntry;
  I: Integer;
begin
  Files := nil;
  SetLength(Files, Length(Items));
  for I := 0 to High(Items) do
  begin
    Files[I].Path := Items[I].Path;
    Files[I].Name := Items[I].Name;
    Files[I].Size := Items[I].Size;
    Files[I].IsDirectory := Items[I].IsDirectory;
  end;
  FCollector.AddMany(Files);
  if FCollector.BlockedNotice <> '' then
    FCollectorBar.ShowNotice(FCollector.BlockedNotice);
  RefreshCollector;
  RefreshList;
end;

{ FolderRowView.menuContent: Add to Collector (off for protected paths),
  Add N Selected when the row is part of a multi-selection, Show in
  Finder, Copy Path; nothing for synthetic rows. }
procedure TMainForm.ListContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  Item: TFolderItem;
  Selected: Integer;
begin
  Handled := True;
  FMenuRow := FList.ItemAtPos(MousePos, True);
  { menuContent is empty for synthetic rows. }
  if not RowItem(FMenuRow, Item) or (Copy(Item.Path, 1, 2) = '::') then
    Exit;
  Selected := 0;
  if FList.Selected[FMenuRow] then
    Selected := FList.SelCount;
  PopUpFileMenu(Item, Selected, FList.ClientToScreen(MousePos));
end;

{ RingsChartView .contextMenu: FileActionsMenu for the segment under the
  pointer, when it is draggable. }
procedure TMainForm.ChartContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  Seg: TRingSegment;
  Item: TFolderItem;
begin
  Handled := True;
  Seg := FChart.DraggableSegmentAt(MousePos.X, MousePos.Y);
  if Seg = nil then
    Exit;
  Item.Path := Seg.Path;
  Item.Name := Seg.Name;
  Item.Size := Seg.Size;
  Item.IsDirectory := Seg.Kind = ckDirectory;
  Item.ItemCount := 0;
  FMenuRow := -1;
  PopUpFileMenu(Item, 0, FChart.ClientToScreen(MousePos));
end;

{ FolderRowView.menuContent / FileActionsMenu: Add to Collector (off for
  protected paths), Add N Selected when SelectedCount > 1, Show in Finder,
  Copy Path. }
procedure TMainForm.PopUpFileMenu(const Item: TFolderItem; SelectedCount: Integer;
  const ScreenPt: TPoint);
begin
  FMenuItem := Item;
  FRowMenu.Items.Clear;
  AddMenuItem('Add to Collector', 'trash', @MenuAddClick, not IsProtectedPath(Item.Path));
  if SelectedCount > 1 then
    AddMenuItem(Format('Add %d Selected to Collector', [SelectedCount]), 'trash',
      @MenuAddSelectedClick);
  AddMenuItem('-', '', nil);
  { FolderRowView: Quick Look when the row has onQuickLook (folder rows,
    not FileActionsMenu on the chart). }
  if FMenuRow >= 0 then
    AddMenuItem('Quick Look', 'eye', @MenuQuickLookClick);
  AddMenuItem('Show in Finder', 'folder', @MenuShowInFinderClick);
  AddMenuItem('Copy Path', 'doc.on.doc', @MenuCopyPathClick);
  FRowMenu.PopUp(ScreenPt.X, ScreenPt.Y);
end;

{ The panes keep their proportion as the window resizes, within the
  minimum widths. }
procedure TMainForm.BodyResize(Sender: TObject);
var
  W: Integer;
begin
  W := Round(FBody.ClientWidth * FSplitRatio);
  W := Min(W, FBody.ClientWidth - FSplitter.Width - ChartMinWidth);
  W := Max(W, ListMinWidth);
  if W <> FListPanel.Width then
    FListPanel.Width := W;
end;

procedure TMainForm.SplitterDrag(Sender: TObject; var NewWidth: Integer);
begin
  NewWidth := Min(NewWidth, FBody.ClientWidth - FSplitter.Width - ChartMinWidth);
  NewWidth := Max(NewWidth, ListMinWidth);
end;

procedure TMainForm.SplitterMoved(Sender: TObject);
begin
  if FBody.ClientWidth > 0 then
    FSplitRatio := FListPanel.Width / FBody.ClientWidth;
end;

{ quickLook(item) / quickLookTarget: the panel shows Row (or, for -1, the
  first selected real row) among every visible real row, so the arrow
  keys move through the list. }
procedure TMainForm.QuickLookRow(Row: Integer);
var
  Paths: array of string;
  Item: TFolderItem;
  I, Start: Integer;
begin
  if Row < 0 then
    for I := 0 to FList.Items.Count - 1 do
      if FList.Selected[I] and RowItem(I, Item) and (Copy(Item.Path, 1, 2) <> '::') then
      begin
        Row := I;
        Break;
      end;
  if (Row < 0) or not RowItem(Row, Item) or (Copy(Item.Path, 1, 2) = '::') then
    Exit;
  { quickLook selects the row it previews. }
  if not FList.Selected[Row] then
  begin
    FList.ClearSelection;
    FList.Selected[Row] := True;
  end;
  Paths := nil;
  Start := 0;
  for I := 0 to FList.Items.Count - 1 do
    if RowItem(I, Item) and (Copy(Item.Path, 1, 2) <> '::') then
    begin
      if I = Row then
        Start := Length(Paths);
      SetLength(Paths, Length(Paths) + 1);
      Paths[High(Paths)] := Item.Path;
    end;
  ShowQuickLook(Self, Paths, Start);
end;

{ CollectedRow .contextMenu: Preview, Show in Finder, Open in Terminal,
  then Remove “name” from Collector. Preview uses the Quick Look panel
  (Swift opens a QuickLookSheet). }
procedure TMainForm.CollectorRowMenu(Sender: TObject; const Path: string;
  const ScreenPt: TPoint);
var
  I: Integer;
  F: TCollectedFile;
  M: TMenuItem;
begin
  F := nil;
  for I := 0 to FCollector.Count - 1 do
    if TCollectedFile(FCollector.Items[I]).Path = Path then
      F := TCollectedFile(FCollector.Items[I]);
  if F = nil then
    Exit;
  FMenuItem.Path := F.Path;
  FMenuItem.Name := F.Name;
  FMenuItem.Size := F.Size;
  FMenuItem.IsDirectory := F.IsDirectory;
  FMenuItem.ItemCount := 0;
  FMenuRow := -1;
  FRowMenu.Items.Clear;
  AddMenuItem('Preview', 'eye', @CollectorPreviewClick);
  AddMenuItem('Show in Finder', 'folder', @MenuShowInFinderClick);
  AddMenuItem('Open in Terminal', 'terminal', @CollectorTerminalClick);
  AddMenuItem('-', '', nil);
  AddMenuItem('Remove “' + F.Name + '” from Collector', 'xmark.circle',
    @CollectorRemoveClick);
  FRowMenu.PopUp(ScreenPt.X, ScreenPt.Y);
end;

procedure TMainForm.CollectorMenuHookTick(Sender: TObject);
var
  I: Integer;
begin
  (Sender as TTimer).Enabled := False;
  I := StrToIntDef(GetEnvironmentVariable('OPENDISK_GUI_COLLECTOR_MENU'), -1);
  if (I >= 0) and (I < FCollector.Count) then
    CollectorRowMenu(nil, TCollectedFile(FCollector.Items[I]).Path,
      FCollectorBar.ClientToScreen(Point(80, 0)));
end;

procedure TMainForm.CollectorPreviewClick(Sender: TObject);
begin
  ShowQuickLook(Self, [FMenuItem.Path], 0);
end;

procedure TMainForm.CollectorTerminalClick(Sender: TObject);
begin
  if FMenuItem.IsDirectory then
    OpenTerminalAt(FMenuItem.Path)
  else
    OpenTerminalAt(ExtractFileDir(FMenuItem.Path));
end;

procedure TMainForm.CollectorRemoveClick(Sender: TObject);
begin
  CollectorRemove(nil, FMenuItem.Path);
end;

procedure TMainForm.A11yDumpTick(Sender: TObject);
begin
  (Sender as TTimer).Enabled := False;
  WriteLn('chart ', DescribeAccessibility(FChart));
  WriteLn('status bar ', DescribeAccessibility(FScanBar));
  Flush(Output);
end;

procedure TMainForm.QuickLookHookTick(Sender: TObject);
begin
  (Sender as TTimer).Enabled := False;
  QuickLookRow(StrToIntDef(GetEnvironmentVariable('OPENDISK_GUI_QUICKLOOK'), -1));
end;

procedure TMainForm.MenuQuickLookClick(Sender: TObject);
begin
  QuickLookRow(FMenuRow);
end;

procedure TMainForm.ChartMenuHookTick(Sender: TObject);
var
  Handled: Boolean;
  P: TPoint;
  Parts: TStringList;
begin
  (Sender as TTimer).Enabled := False;
  Parts := TStringList.Create;
  try
    Parts.CommaText := GetEnvironmentVariable('OPENDISK_GUI_CHART_MENU');
    if Parts.Count <> 2 then
      Exit;
    { Offsets from the chart centre. }
    P := Point(FChart.ClientWidth div 2 + StrToIntDef(Parts[0], 0),
      FChart.ClientHeight div 2 + StrToIntDef(Parts[1], 0));
  finally
    Parts.Free;
  end;
  ChartContextPopup(FChart, P, Handled);
end;

procedure TMainForm.ConfirmHookTick(Sender: TObject);
begin
  (Sender as TTimer).Enabled := False;
  DeleteClick(nil);
end;

procedure TMainForm.MenuHookTick(Sender: TObject);
var
  Row: Integer;
  Handled: Boolean;
  R: TRect;
begin
  (Sender as TTimer).Enabled := False;
  Row := StrToIntDef(GetEnvironmentVariable('OPENDISK_GUI_MENU'), -1);
  if (Row < 0) or (Row >= FList.Items.Count) then
    Exit;
  R := FList.ItemRect(Row);
  ListContextPopup(FList, Point(R.Left + 60, (R.Top + R.Bottom) div 2), Handled);
end;

procedure TMainForm.MenuAddClick(Sender: TObject);
begin
  StageItems([FMenuItem]);
end;

procedure TMainForm.MenuAddSelectedClick(Sender: TObject);
var
  Items: array of TFolderItem;
  Item: TFolderItem;
  I: Integer;
begin
  Items := nil;
  for I := 0 to FList.Items.Count - 1 do
    { The protected ones are left out, as Swift filters them. }
    if FList.Selected[I] and RowItem(I, Item) and not IsProtectedPath(Item.Path) then
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)] := Item;
    end;
  StageItems(Items);
end;

procedure TMainForm.MenuShowInFinderClick(Sender: TObject);
begin
  RevealInFileManager(FMenuItem.Path);
end;

procedure TMainForm.MenuCopyPathClick(Sender: TObject);
begin
  Clipboard.AsText := FMenuItem.Path;
end;

procedure TMainForm.CollectorRemove(Sender: TObject; const Path: string);
begin
  FCollector.Remove(Path);
  RefreshCollector;
  RefreshList;
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
  NameTop, Right, SizeLeft, CapLeft, MidY, W, TextLeft, Count: Integer;
  RowSize: Int64;
  SizeKnown: Boolean;
  FullName, Location: string;
  IconRect: TRect;
  Frac: Double;
begin
  LB := Control as TListBox;
  C := LB.Canvas;
  if (Index < 0) or (Index >= LB.Items.Count) then
    Exit;
  Node := TNodeID(PtrUInt(LB.Items.Objects[Index]));
  if (FTree = nil) and (Node > SkeletonRowBase) then
    Exit;
  Location := '';
  SizeKnown := True;
  if Node <= SkeletonRowBase then
  begin
    IsDir := FSkeleton[SkeletonRowBase - Node].IsDirectory;
    RowSize := FSkeleton[SkeletonRowBase - Node].Size;
    FullName := FSkeleton[SkeletonRowBase - Node].Name;
    Count := 0;
    { FolderItem.sizeIsKnown: '--' and no capsule for folders. }
    SizeKnown := FSkeleton[SkeletonRowBase - Node].SizeKnown;
  end
  else if Node <= SearchRowBase then
  begin
    { SearchResultsView row: FolderRowView with the parent folder as its
      location line. }
    with FSearchItems[SearchRowBase - Node] do
    begin
      IsDir := IsDirectory;
      RowSize := Size;
      FullName := Name;
      Count := 0;
      Location := ExtractFileDir(Path);
      if (FHome <> '') and (Copy(Location, 1, Length(FHome)) = FHome) then
        Location := '~' + Copy(Location, Length(FHome) + 1, MaxInt);
    end;
  end
  else if Node = PurgeableRowID then
  begin
    { DiskAnalyzer.display(node:): the cache summary row. }
    IsDir := True;
    RowSize := FPurgeableTotal;
    FullName := HiddenSpaceFolderName;
    Count := FPurgeableCount;
  end
  else if (FCurrentPath = HiddenSpaceSentinelPath) and (Index <= High(FPurgeableEntries)) then
  begin
    { displayCleanableSpace: catalogue name, no item count. }
    IsDir := True;
    RowSize := FPurgeableEntries[Index].Size;
    FullName := FPurgeableEntries[Index].Name;
    Count := 0;
  end
  else
  begin
    IsDir := FTree.IsDirectory(Node);
    RowSize := FTree.SizeOf(Node);
    FullName := FTree.NameOf(Node);
    if IsDir then
      Count := FTree.ChildCount(Node)
    else
      Count := 0;
  end;
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
  if SizeKnown then
    SizeText := FormatFileSize(RowSize)
  else
    SizeText := '--';
  { System font: CLAUDE.md forbids a monospaced font in the file list, and
    LCL cannot request monospaced digits; the fixed right-aligned column
    keeps sizes from shifting. }
  C.Font.Name := 'default';
  C.Font.Size := 12;
  C.Font.Style := [];
  if SizeKnown then
    C.Font.Color := Secondary
  else
    C.Font.Color := Tertiary;
  SizeLeft := Right - SizeW;
  C.TextOut(Right - C.TextWidth(SizeText), MidY - C.TextHeight(SizeText) div 2, SizeText);
  Right := SizeLeft - Gap;

  { size capsule against the largest sibling }
  if (FListMaxSize > 0) and SizeKnown then
  begin
    Frac := RowSize / FListMaxSize;
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
  IconRect := Rect(Row.Left + PadX, MidY - IconSize div 2,
    Row.Left + PadX + IconSize, MidY - IconSize div 2 + IconSize);
  { FolderRowView: a synthetic folder gets the generic folder icon. }
  if Node = PurgeableRowID then
    DrawFolderIcon(C, IconRect)
  else if Node <= SkeletonRowBase then
    DrawFileIcon(C, IconRect, FSkeleton[SkeletonRowBase - Node].Path, IsDir)
  else if Node <= SearchRowBase then
    DrawFileIcon(C, IconRect, FSearchItems[SearchRowBase - Node].Path, IsDir)
  else
    DrawFileIcon(C, IconRect, FTree.PathOf(Node), IsDir);
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
  RowName := FullName;
  { Too long for the name column: truncate in the middle (CLAUDE.md:
    preserve the start and the extension) rather than clip. }
  Keep := CodePointCount(RowName);
  while (C.TextWidth(RowName) > Right - TextLeft) and (Keep > 6) do
  begin
    Dec(Keep);
    RowName := TruncateMiddle(FullName, Keep);
  end;
  Detail := '';
  if IsDir and (Count > 0) then
    Detail := Format('%d items', [Count]);
  if Location <> '' then
  begin
    { .truncationMode(.middle) }
    C.Font.Size := 10;
    Keep := CodePointCount(Location);
    Detail := Location;
    while (C.TextWidth(Detail) > Right - TextLeft) and (Keep > 6) do
    begin
      Dec(Keep);
      Detail := TruncateMiddle(Location, Keep);
    end;
  end;
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

{ DiskAnalysisView.showContents(of:): the tree's folder, the Purgeable
  view, or — when the tree does not hold it and nothing is scanning — a
  scan of that folder within this analysis. }
function TMainForm.ShowContentsOf(const Path: string): Boolean;
var
  ScanName: string;
begin
  Result := False;
  if FTree <> nil then
  begin
    if Path = HiddenSpaceSentinelPath then
    begin
      Result := Length(CleanableCacheEntriesOf(FTree, FRootPath)) > 0;
      if Result then
        ShowNode(Path);
      Exit;
    end;
    if ResolveNode(FTree, FRootPath, Path) <> NoNode then
    begin
      ShowNode(Path);
      Exit(True);
    end;
  end;
  if (FScanThread <> nil) or (Copy(Path, 1, 2) = '::') or not DirectoryExists(Path) then
    Exit;
  if Path = FViewRoot then
    ScanName := FViewRootName
  else
    ScanName := ExtractFileName(ExcludeTrailingPathDelimiter(Path));
  StartScan(Path, ScanName, FRootTotal, FRootFree, True);
  Result := True;
end;

{ DiskAnalysisView.navigateToPath: going to a folder already on the back
  stack drops everything after it; otherwise the current one is pushed. }
procedure TMainForm.NavigateToPath(const Path: string);
var
  FromPath: string;
  Index: Integer;
begin
  if Path = FCurrentPath then
    Exit;
  FromPath := FCurrentPath;
  if not ShowContentsOf(Path) then
    Exit;
  Index := FBreadcrumbs.IndexOf(Path);
  if Index >= 0 then
    while FBreadcrumbs.Count > Index do
      FBreadcrumbs.Delete(FBreadcrumbs.Count - 1)
  else
    FBreadcrumbs.Add(FromPath);
  FCurrentPath := Path;
end;

procedure TMainForm.CrumbNavigate(const Path: string);
begin
  NavigateToPath(Path);
end;

procedure TMainForm.ListDblClick(Sender: TObject);
var
  Child: TNodeID;
  ChildPath: string;
begin
  if FList.ItemIndex < 0 then
    Exit;
  Child := TNodeID(PtrUInt(FList.Items.Objects[FList.ItemIndex]));
  { Skeleton rows have no tree to open yet. }
  if Child <= SkeletonRowBase then
    Exit;
  if Child <= SearchRowBase then
  begin
    OpenSearchResult(SearchRowBase - Child);
    Exit;
  end;
  if FTree = nil then
    Exit;
  if Child = PurgeableRowID then
  begin
    NavigateToPath(HiddenSpaceSentinelPath);
    Exit;
  end;
  ChildPath := FTree.PathOf(Child);
  if FTree.IsDirectory(Child) then
    NavigateToPath(ChildPath)
  else
  begin
    if not FCollector.Add(ChildPath, FTree.NameOf(Child), FTree.SizeOf(Child), False) and
      (FCollector.BlockedNotice <> '') then
      FCollectorBar.ShowNotice(FCollector.BlockedNotice);
    RefreshCollector;
    RefreshList;
  end;
end;

procedure TMainForm.ChartSelect(Sender: TObject; const APath: string;
  IsCenter: Boolean);
begin
  { onSelectCenter: goBack; onSelectDirectory: navigateToPath. }
  if IsCenter then
    BackClick(nil)
  else
    NavigateToPath(APath);
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
  { goBack: the previous folder must show (or start scanning) first. }
  if FBreadcrumbs.Count = 0 then
    Exit;
  Prev := FBreadcrumbs[FBreadcrumbs.Count - 1];
  if not ShowContentsOf(Prev) then
    Exit;
  FBreadcrumbs.Delete(FBreadcrumbs.Count - 1);
  FCurrentPath := Prev;
end;

{ DiskAnalysisView.swift refresh(): a new scan rooted at the folder being
  shown, which becomes the scan root. }
procedure TMainForm.RefreshClick(Sender: TObject);
var
  ScanName: string;
begin
  if FCurrentPath = '' then
    Exit;
  { refresh(): scanDirectory(currentPath, or rootPath for '::' views);
    the view root and back stack stay. }
  if (Copy(FCurrentPath, 1, 2) = '::') or (FCurrentPath = FViewRoot) then
  begin
    StartScan(FViewRoot, FViewRootName, FRootTotal, FRootFree, True);
    Exit;
  end;
  ScanName := ExtractFileName(ExcludeTrailingPathDelimiter(FCurrentPath));
  StartScan(FCurrentPath, ScanName, FRootTotal, FRootFree, True);
end;

procedure TMainForm.DeleteClick(Sender: TObject);
var
  Title: string;
begin
  if (FCollector.Count = 0) or (FDeleteJob <> nil) then
    Exit;
  { CollectorBar confirmationDialog. }
  if FCollector.Count = 1 then
    Title := 'Delete 1 item?'
  else
    Title := Format('Delete %d items?', [FCollector.Count]);
  if not ConfirmDestructive(Title,
    'This permanently deletes the collected items and can’t be undone.',
    'Delete ' + FormatFileSize(FCollector.TotalBytes)) then
    Exit;
  { performDeletion: delete in the background, show progress. }
  FDoneTimer.Enabled := False;
  FDeleteJob := FCollector.StartDelete;
  FCollectorBar.SetPhase(cbDeleting);
  FCollectorBar.SetDeletionProgress('', 0, 0, FCollector.Count);
  FDeletePoll.Enabled := True;
end;

procedure TMainForm.DeletePollTick(Sender: TObject);
var
  P: TDeletionProgress;
  Freed: Int64;
begin
  if FDeleteJob = nil then
  begin
    FDeletePoll.Enabled := False;
    Exit;
  end;
  P := FDeleteJob.Progress;
  FCollectorBar.SetDeletionProgress(P.CurrentName, P.FreedBytes, P.Completed, P.Total);
  if not FDeleteJob.Finished then
    Exit;
  FDeletePoll.Enabled := False;
  Freed := FCollector.FinishDelete(FDeleteJob);
  FDeleteJob := nil;
  { Done phase for 2 s; onDeleted rescans the root right away. }
  FCollectorBar.SetPhase(cbDone);
  FCollectorBar.SetDoneResult(Freed, FCollector.Failures.Count);
  FDoneTimer.Enabled := True;
  RefreshCollector;
  { CollectorBar onDeleted: back to the view root, rescanned. }
  FBreadcrumbs.Clear;
  StartScan(FViewRoot, FViewRootName, FRootTotal, FRootFree, True);
end;

procedure TMainForm.DoneTimerTick(Sender: TObject);
begin
  FDoneTimer.Enabled := False;
  RefreshCollector;
end;

end.
