{ Main OpenDisk GUI — volume picker first, then analysis (list + rings).

  Layout mirrors Swift ContentView → DevicePickerView → DiskAnalysisView:
  home screen is disk selection; scanning only starts after a choice. }

unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, ComCtrls, Buttons, RingsChart, FileTree, Traversal,
  ChartItem, Formatters, Collector, ProtectedPaths, Volumes;

type
  TUIMode = (umPicker, umScanning, umAnalysis);

  TScanThread = class(TThread)
  private
    FPath: string;
    FTree: TFileTree;
    FBytes: Int64;
    FItems: Integer;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string);
    property Tree: TFileTree read FTree;
    property Error: string read FError;
    property Bytes: Int64 read FBytes;
    property Items: Integer read FItems;
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
    FVolumes: TVolumeInfoArray;
    { Analysis chrome }
    FAnalysis: TPanel;
    FNav: TPanel;
    FDisksBtn: TButton;
    FBackBtn: TButton;
    FCrumb: TLabel;
    FRefreshBtn: TButton;
    FBody: TPanel;
    FListPanel: TPanel;
    FListHeader: TLabel;
    FList: TListBox;
    FChartPanel: TPanel;
    FChart: TRingsChart;
    FCollectorPanel: TPanel;
    FCollectorLabel: TLabel;
    FDeleteButton: TButton;
    FStatus: TStatusBar;
    FCollector: TCollector;
    FTree: TFileTree;
    FCurrentPath: string;
    FRootPath: string;
    FRootName: string;
    FRootTotal: QWord;
    FRootFree: QWord;
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
    procedure ScanFinished;
    procedure ShowNode(const APath: string);
    procedure RefreshList;
    procedure RefreshCollector;
    procedure VolListDrawItem(Control: TWinControl; Index: Integer;
      ARect: TRect; State: TOwnerDrawState);
    procedure VolListDblClick(Sender: TObject);
    procedure VolListKeyPress(Sender: TObject; var Key: Char);
    procedure FolderClick(Sender: TObject);
    procedure RefreshVolClick(Sender: TObject);
    procedure ListDblClick(Sender: TObject);
    procedure ChartSelect(Sender: TObject; const APath: string; IsCenter: Boolean);
    procedure DisksClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormResize(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  MainForm: TMainForm;

implementation

uses
  LCLType, LCLIntf, PlatformFS;

const
  CBg      = $001C1A18; { near-black warm }
  CPanel   = $00262220;
  CPanel2  = $002E2926;
  CRule    = $003D3733;
  CInk     = $00F2EEE8;
  CMuted   = $009A9188;
  CAccent  = $00E48435; { steel-blue in BGR — matches rings palette }
  CBarTrack = $00403834;
  CBarFill = $0035A0E0; { warm amber fill }
  CDanger  = $00333AE0;

var
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
end;

procedure TScanThread.SetProgress(ABytes: Int64; AItems: Integer);
begin
  FBytes := ABytes;
  FItems := AItems;
end;

procedure ScanProgressThunk(BytesScanned: Int64; ItemsScanned: Integer);
begin
  if ActiveScanThread <> nil then
    ActiveScanThread.SetProgress(BytesScanned, ItemsScanned);
end;

procedure TScanThread.Execute;
begin
  ActiveScanThread := Self;
  try
    try
      FTree := ScanPath(FPath, @ScanProgressThunk);
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
  ShowPicker;
  RefreshVolumes;
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
  FPickerSub.Font.Color := CMuted;
  FPickerSub.Left := 50;
  FPickerSub.Top := 86;

  FVolList := TListBox.Create(Self);
  FVolList.Parent := FPicker;
  FVolList.Left := 48;
  FVolList.Top := 130;
  FVolList.Width := 520;
  FVolList.Height := 420;
  FVolList.Style := lbOwnerDrawFixed;
  FVolList.ItemHeight := 64;
  FVolList.BorderStyle := bsNone;
  FVolList.Color := CPanel;
  FVolList.OnDrawItem := @VolListDrawItem;
  FVolList.OnDblClick := @VolListDblClick;
  FVolList.OnKeyPress := @VolListKeyPress;

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
  FRefreshVolBtn.Left := 200;
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
  FDisksBtn.Caption := 'Disks';
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

  FCrumb := TLabel.Create(Self);
  FCrumb.Parent := FNav;
  FCrumb.Left := 144;
  FCrumb.Top := 16;
  FCrumb.Font.Size := 12;
  FCrumb.Font.Color := CInk;
  FCrumb.Caption := '';

  FRefreshBtn := TButton.Create(Self);
  FRefreshBtn.Parent := FNav;
  FRefreshBtn.Caption := 'Refresh';
  FRefreshBtn.Width := 88;
  FRefreshBtn.Height := 28;
  FRefreshBtn.Top := 12;
  FRefreshBtn.Anchors := [akTop, akRight];
  FRefreshBtn.OnClick := @RefreshClick;

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
  FCollectorLabel.Font.Color := CMuted;
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
  FListHeader.Font.Color := CMuted;

  FList := TListBox.Create(Self);
  FList.Parent := FListPanel;
  FList.Align := alClient;
  FList.BorderStyle := bsNone;
  FList.Color := CPanel;
  FList.Font.Color := CInk;
  FList.Font.Name := 'Menlo';
  FList.Font.Size := 11;
  FList.OnDblClick := @ListDblClick;

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
end;

procedure TMainForm.StyleChrome;
begin
  Color := CBg;
  FRefreshBtn.Left := Width - FRefreshBtn.Width - 24;
  FDeleteButton.Left := Width - FDeleteButton.Width - 24;
end;

procedure TMainForm.FormResize(Sender: TObject);
begin
  FRefreshBtn.Left := Max(200, Width - FRefreshBtn.Width - 24);
  FDeleteButton.Left := Max(200, Width - FDeleteButton.Width - 24);
  FVolList.Width := Min(560, Max(420, Width - 96));
  FVolList.Height := Max(200, Height - 260);
  FFolderBtn.Top := FVolList.Top + FVolList.Height + 20;
  FRefreshVolBtn.Top := FFolderBtn.Top;
end;

procedure TMainForm.ShowPicker;
begin
  FMode := umPicker;
  FAnalysis.Visible := False;
  FPicker.Visible := True;
  FPicker.BringToFront;
  FStatus.SimpleText := 'Select a disk to analyze';
  Caption := 'OpenDisk';
end;

procedure TMainForm.ShowAnalysis;
begin
  FMode := umAnalysis;
  FPicker.Visible := False;
  FAnalysis.Visible := True;
  FAnalysis.BringToFront;
  StyleChrome;
end;

procedure TMainForm.RefreshVolumes;
var
  I: Integer;
begin
  FVolumes := ListVolumes;
  FVolList.Items.BeginUpdate;
  try
    FVolList.Clear;
    for I := 0 to High(FVolumes) do
      FVolList.Items.Add(FVolumes[I].Name);
  finally
    FVolList.Items.EndUpdate;
  end;
  if FVolList.Items.Count > 0 then
    FVolList.ItemIndex := 0;
  FStatus.SimpleText := Format('%d volume(s)', [Length(FVolumes)]);
end;

procedure TMainForm.VolListDrawItem(Control: TWinControl; Index: Integer;
  ARect: TRect; State: TOwnerDrawState);
var
  LB: TListBox;
  Vol: TVolumeInfo;
  UsedFrac: Double;
  Bar, Fill: TRect;
  Used, Line2: string;
  Selected: Boolean;
begin
  LB := Control as TListBox;
  if (Index < 0) or (Index > High(FVolumes)) then
    Exit;
  Vol := FVolumes[Index];
  Selected := odSelected in State;

  if Selected then
    LB.Canvas.Brush.Color := CPanel2
  else
    LB.Canvas.Brush.Color := CPanel;
  LB.Canvas.FillRect(ARect);

  { left accent }
  LB.Canvas.Brush.Color := CAccent;
  LB.Canvas.FillRect(Rect(ARect.Left, ARect.Top + 10, ARect.Left + 3, ARect.Bottom - 10));

  LB.Canvas.Brush.Style := bsClear;
  LB.Canvas.Font.Color := CInk;
  LB.Canvas.Font.Size := 13;
  LB.Canvas.Font.Style := [fsBold];
  LB.Canvas.TextOut(ARect.Left + 16, ARect.Top + 10, Vol.Name);

  if Vol.TotalBytes > 0 then
  begin
    Used := FormatFileSize(Int64(Vol.TotalBytes - Vol.AvailableBytes)) + ' used · ' +
      FormatFileSize(Int64(Vol.AvailableBytes)) + ' available';
    Line2 := Vol.Path + '  ·  ' + Used;
  end
  else
    Line2 := Vol.Path;

  LB.Canvas.Font.Size := 10;
  LB.Canvas.Font.Style := [];
  LB.Canvas.Font.Color := CMuted;
  LB.Canvas.TextOut(ARect.Left + 16, ARect.Top + 32, Line2);

  if Vol.TotalBytes > 0 then
  begin
    UsedFrac := Double(Vol.TotalBytes - Vol.AvailableBytes) / Double(Vol.TotalBytes);
    if UsedFrac < 0 then UsedFrac := 0;
    if UsedFrac > 1 then UsedFrac := 1;
    Bar := Rect(ARect.Right - 140, ARect.Top + 28, ARect.Right - 16, ARect.Top + 36);
    LB.Canvas.Brush.Style := bsSolid;
    LB.Canvas.Brush.Color := CBarTrack;
    LB.Canvas.FillRect(Bar);
    Fill := Bar;
    Fill.Right := Bar.Left + Round((Bar.Right - Bar.Left) * UsedFrac);
    LB.Canvas.Brush.Color := CBarFill;
    if Fill.Right > Fill.Left then
      LB.Canvas.FillRect(Fill);
  end;
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
  if FScanThread <> nil then
  begin
    FScanThread.Terminate;
    FScanThread.WaitFor;
    FScanThread.Free;
  end;
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
  else if (Key = VK_LEFT) and (ssMeta in Shift) and (FMode = umAnalysis) then
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
begin
  Expanded := ResolvePath(APath);
  if not DirectoryExists(Expanded) then
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
  FCollector.Clear;
  RefreshCollector;
  FMode := umScanning;
  ShowAnalysis;
  FCrumb.Caption := FRootName + '  —  preparing…';
  Caption := FRootName + ' — OpenDisk';
  FStatus.SimpleText := 'Scanning ' + Expanded + '…';
  FDisksBtn.Enabled := False;
  FBackBtn.Enabled := False;
  FRefreshBtn.Enabled := False;
  FScanThread := TScanThread.Create(Expanded);
  FScanThread.Start;
  FPoll.Enabled := True;
end;

procedure TMainForm.OnPoll(Sender: TObject);
begin
  if FScanThread = nil then
  begin
    FPoll.Enabled := False;
    Exit;
  end;
  FStatus.SimpleText := Format('Scanning: %s (%d items)',
    [FormatFileSize(FScanThread.Bytes), FScanThread.Items]);
  FCrumb.Caption := FRootName + '  —  ' + FormatFileSize(FScanThread.Bytes);
  if FScanThread.Finished then
  begin
    FPoll.Enabled := False;
    ScanFinished;
  end;
end;

procedure TMainForm.ScanFinished;
var
  Thread: TScanThread;
  Cap: string;
begin
  Thread := FScanThread;
  FScanThread := nil;
  FDisksBtn.Enabled := True;
  FBackBtn.Enabled := True;
  FRefreshBtn.Enabled := True;
  try
    if Thread.Error <> '' then
    begin
      FStatus.SimpleText := 'Scan failed: ' + Thread.Error;
      FMode := umPicker;
      ShowPicker;
      Exit;
    end;
    FTree := Thread.Tree;
    Thread.FTree := nil;
    FMode := umAnalysis;
    Cap := '';
    if FRootTotal > 0 then
      Cap := Format(' · volume %s / %s',
        [FormatFileSize(Int64(FRootTotal - FRootFree)),
         FormatFileSize(Int64(FRootTotal))]);
    FStatus.SimpleText := Format('%s · %d items%s',
      [FormatFileSize(FTree.SizeOf(RootID)), FTree.NodeCount - 1, Cap]);
    ShowNode(FRootPath);
  finally
    Thread.Free;
  end;
end;

function ResolveNode(Tree: TFileTree; const RootPath, APath: string): TNodeID;
begin
  Result := Tree.NodeIDForPath(APath, RootPath);
end;

procedure TMainForm.ShowNode(const APath: string);
var
  Node: TNodeID;
  NodeName: string;
  Chart: TChartItem;
  Rel: string;
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
  if APath = FRootPath then
    Rel := FRootName
  else
  begin
    Rel := Copy(APath, Length(IncludeTrailingPathDelimiter(FRootPath)) + 1, MaxInt);
    Rel := FRootName + ' / ' + StringReplace(Rel, DirectorySeparator, ' / ', [rfReplaceAll]);
  end;
  FCrumb.Caption := Rel + '  ·  ' + FormatFileSize(FTree.SizeOf(Node));
  FListHeader.Caption := 'Largest in ' + NodeName;
  RefreshList;
  FBackBtn.Enabled := FBreadcrumbs.Count > 0;
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
        Line := Format('%10s   %s',
          [FormatFileSize(FTree.SizeOf(Child)), FTree.NameOf(Child)]);
        if FTree.IsDirectory(Child) then
          Line := Line + DirectorySeparator;
        FList.Items.AddObject(Line, TObject(PtrUInt(Child)));
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

procedure TMainForm.DisksClick(Sender: TObject);
begin
  if FScanThread <> nil then
    Exit;
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

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  if FRootPath <> '' then
    StartScan(FRootPath, FRootName, FRootTotal, FRootFree);
end;

procedure TMainForm.DeleteClick(Sender: TObject);
var
  Freed: Int64;
begin
  if FCollector.Count = 0 then
    Exit;
  if MessageDlg(Format('Permanently delete %d item(s) (%s)? This skips Trash.',
    [FCollector.Count, FormatFileSize(FCollector.TotalBytes)]),
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  Freed := FCollector.DeleteAll;
  RefreshCollector;
  if FCollector.Failures.Count > 0 then
    FStatus.SimpleText := Format('Freed %s; %d item(s) could not be deleted and stay staged — rescanning…',
      [FormatFileSize(Freed), FCollector.Failures.Count])
  else
    FStatus.SimpleText := 'Freed ' + FormatFileSize(Freed) + ' — rescanning…';
  StartScan(FRootPath, FRootName, FRootTotal, FRootFree);
end;

end.
