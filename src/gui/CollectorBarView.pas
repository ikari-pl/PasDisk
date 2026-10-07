{ CollectorBarView — the collector footer and its overlays.

  Port of Views/Components/CollectorBar.swift (pre-macOS 26 look). The
  view itself is the footer panel: a rounded (16 pt) light material panel
  with a soft shadow, an 18% tint and a 1.5 pt border while targeted
  (accent) or rejecting (red). Its content follows the phase: the hint,
  the collected total with a red Delete capsule, the deletion progress, or
  the 'Freed' result. Two floating panels live in the same parent, above
  the footer: the staged list (shown while the footer or the list is
  hovered, rows of 30 pt, closing 160 ms after the pointer leaves) and the
  blocked notice (orange, hidden after 3.5 s).

  The owner drives everything: no Collector access in here. }

unit CollectorBarView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Graphics, Controls, ExtCtrls, Types, Motion, PlatformMotion;

type
  TCollectorPhase = (cbIdle, cbTargeted, cbRejecting, cbDeleting, cbDone);

  TCollectorItem = record
    Name, Path: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;
  TCollectorItems = array of TCollectorItem;

  TCollectorButtonEvent = procedure(Sender: TObject) of object;
  TCollectorRemoveEvent = procedure(Sender: TObject; const Path: string) of object;
  { A drag out of the collector began from Source (CollectorBar fileDrag
    with exportsFileURLs: false): one row, or every item from the footer. }
  TCollectorDragOutEvent = procedure(Sender: TObject; Source: TWinControl;
    const Paths: array of string) of object;

  { CollectedRow .contextMenu was asked for at ScreenPt. }
  TCollectorRowMenuEvent = procedure(Sender: TObject; const Path: string;
    const ScreenPt: TPoint) of object;

  { .contentTransition(.numericText()): a number rolling from its old
    text to the new one. }
  TRollingText = record
    Anim: TAnimatedValue;
    OldText: string;
    Up: Boolean;
  end;

  TCollectorBarView = class;

  { A floating rounded panel above the footer: the staged list or the
    notice. }
  TCollectorOverlay = class(TCustomControl)
  private
    FBar: TCollectorBarView;
    FIsList: Boolean;
    FHover: Integer;
    FPressRow, FPressX, FPressY: Integer;
    FDragged: Boolean;
    { .transition(.opacity.combined(with: .move(edge: .bottom))): 1 shown,
      0 gone; FRestTop is where it sits when shown. }
    FShown: TAnimatedValue;
    FRestTop: Integer;
    { .hoverHighlight(cornerRadius: 6): rows fade their wash (0.15 s). }
    FHoverRows: array of Integer;
    FHoverFades: array of TAnimatedValue;
    { ScrollView offset: the list scrolls once its rows outgrow the panel. }
    FScroll: Integer;
    procedure SetHover(Row: Integer);
    function HoverAmount(Row: Integer; NowMs: QWord): Double;
    function HoverMoving(NowMs: QWord): Boolean;
    procedure PruneHover(NowMs: QWord);
    function MaxScroll: Integer;
    function RowAt(Y: Integer): Integer;
  protected
    procedure Paint; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DoContextPopup(MousePos: TPoint; var Handled: Boolean); override;
  public
    constructor CreateFor(Bar: TCollectorBarView; IsList: Boolean);
  end;

  TCollectorBarView = class(TCustomControl)
  private
    FItems: TCollectorItems;
    FPhase: TCollectorPhase;
    FRejectReason: string;
    FDeletingName: string;
    FFreedBytes: Int64;
    FCompleted, FTotal: Integer;
    FDoneFreed: Int64;
    FDoneFailures: Integer;
    FNotice: string;
    FList, FNoticePanel: TCollectorOverlay;
    FFooterHovered, FListHovered, FForceList: Boolean;
    FCollapse, FNoticeTimer, FSpin: TTimer;
    FSpinStart: QWord;
    FDeleteRect: TRect;
    FOnDeleteClick: TCollectorButtonEvent;
    FOnRemoveItem: TCollectorRemoveEvent;
    FOnDragOut: TCollectorDragOutEvent;
    FOnRowMenu: TCollectorRowMenuEvent;
    { collector.draggingOut != nil: the list hides and nothing targets. }
    FDraggingOut: Boolean;
    FPressed, FDragged: Boolean;
    FPressX, FPressY: Integer;
    FMotion: TFrameClock;
    { .animation(.easeInOut(duration: 0.15), value: collecting/rejecting):
      the drag tint fades in and out; FTintColor is the last one shown. }
    FTint: TAnimatedValue;
    FTintColor: TColor;
    { .contentTransition(.numericText()) with .spring(0.3) on the count:
      the total rolls from the old text to the new (up when it grows). }
    FTotalRoll: TRollingText;
    { The freed bytes while deleting (.snappy(0.25) on deletionProgress). }
    FFreedRoll: TRollingText;
    procedure StartRoll(var Roll: TRollingText; const OldText: string; Up: Boolean;
      DurationMs: Integer; Easing: TEasing);
    function TintColorFor(Phase: TCollectorPhase): TColor;
    procedure ShowOverlay(O: TCollectorOverlay; const R: TRect);
    procedure HideOverlay(O: TCollectorOverlay);
    procedure PlaceOverlay(O: TCollectorOverlay; NowMs: QWord);
    procedure MotionFrame(Sender: TObject);
    procedure StartMotion;
    procedure DrawRolling(C: TCanvas; X, Y: Integer; const NewText: string;
      const Roll: TRollingText);
    procedure CollapseTick(Sender: TObject);
    procedure NoticeTick(Sender: TObject);
    procedure SpinTick(Sender: TObject);
    procedure UpdateOverlays;
    procedure UpdateHeight;
    function WantsList: Boolean;
    function TotalBytes: Int64;
    function PanelColor: TColor;
    { Amount scales the tint and border, for fades. }
    procedure DrawPanel(C: TCanvas; const R: TRect; Tint: TColor; HasTint: Boolean;
      BorderColor: TColor; HasBorder: Boolean; Amount: Double = 1);
    procedure DrawSymbol(C: TCanvas; const SymName: string; X, Y, Size: Integer; SymColor: TColor);
    procedure ListHover(Value: Boolean);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure SetParent(NewParent: TWinControl); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetDraggingOut(Value: Boolean);
    { The drag ended; its mouse-up never reaches the control. }
    procedure DragFinished;
    { keepZones: the footer, and the list while it shows. }
    function InKeepZone(const ScreenPt: TPoint): Boolean;
    destructor Destroy; override;
    procedure SetItems(const Items: TCollectorItems);
    { cbTargeted / cbRejecting describe a drag; RejectReason is shown while
      rejecting (CollectorBar.swift rejectionView). }
    procedure SetPhase(Phase: TCollectorPhase; const RejectReason: string = '');
    procedure SetDeletionProgress(const CurrentName: string; FreedBytes: Int64;
      Completed, Total: Integer);
    procedure SetDoneResult(FreedBytes: Int64; Failures: Integer);
    procedure ShowNotice(const NoticeText: string);
    { Screenshots: keep the staged list open without hovering. }
    procedure SetListVisible(Value: Boolean);
    property OnDeleteClick: TCollectorButtonEvent read FOnDeleteClick write FOnDeleteClick;
    property OnRemoveItem: TCollectorRemoveEvent read FOnRemoveItem write FOnRemoveItem;
    property OnDragOut: TCollectorDragOutEvent read FOnDragOut write FOnDragOut;
    property OnRowMenu: TCollectorRowMenuEvent read FOnRowMenu write FOnRowMenu;
  end;

implementation

uses
  LCLType, LCLIntf, PlatformImages, GuiColors, Formatters, TextTrim, DesignTokens, PlatformAppearance;

const
  Radius = 16;
  PadH = 14;
  PadV = 10;
  ShadowSpace = 6;
  RowHeight = 30;
  ListGap = 8;
  { System colours (.red, .green, .orange) for state, not decoration. }
  SystemRed = TColor($00303BFF);
  SystemGreen = TColor($0059C734);
  SystemOrange = TColor($000095FF);
  { .callout / .headline / .caption on macOS. }
  CalloutSize = 12; { .callout, CollectorBar.swift:197-200 }
  HeadlineSize = 13; { .headline, CollectorBar.swift:162-165 }
  CaptionSize = 10; { .caption, CollectorBar.swift:166-168 }

function Blend(A, B: TColor; T: Double): TColor;
begin
  A := ColorToRGB(A);
  B := ColorToRGB(B);
  Result := RGBToColor(
    Round(Red(A) + (Red(B) - Red(A)) * T),
    Round(Green(A) + (Green(B) - Green(A)) * T),
    Round(Blue(A) + (Blue(B) - Blue(A)) * T));
end;

{ ---- TCollectorOverlay ---- }

constructor TCollectorOverlay.CreateFor(Bar: TCollectorBarView; IsList: Boolean);
begin
  inherited Create(Bar);
  FBar := Bar;
  FIsList := IsList;
  FHover := -1;
  FPressRow := -1;
  ControlStyle := ControlStyle + [csOpaque];
  Visible := False;
end;

procedure TCollectorOverlay.Paint;
var
  C: TCanvas;
  Panel, R: TRect;
  I, Y, X, W: Integer;
  Secondary: TColor;
  SizeText, RowName: string;
  Keep: Integer;
  Amount: Double;
begin
  C := Canvas;
  C.Brush.Style := bsSolid;
  C.Brush.Color := ColorToRGB(Parent.Color);
  C.FillRect(ClientRect);
  Panel := Rect(0, 0, ClientWidth, ClientHeight - ShadowSpace);
  if not FIsList then
  begin
    { noticeBanner: lock.fill + text, orange on an orange 18% tint. }
    FBar.DrawPanel(C, Panel, SystemOrange, True, clNone, False);
    FBar.DrawSymbol(C, 'lock.fill', Panel.Left + PadH, (Panel.Top + Panel.Bottom) div 2 - 7,
      14, SystemOrange);
    C.Brush.Style := bsClear;
    C.Font.Size := CalloutSize;
    C.Font.Style := [];
    C.Font.Color := SystemOrange;
    R := Rect(Panel.Left + PadH + 22, Panel.Top + PadV, Panel.Right - PadH, Panel.Bottom - PadV);
    DrawText(C.Handle, PChar(FBar.FNotice), Length(FBar.FNotice), R,
      DT_WORDBREAK or DT_NOPREFIX or DT_VCENTER);
    Exit;
  end;
  { listPanel: CollectedRow per item — remove x, 18 pt icon, name, size. }
  FBar.DrawPanel(C, Panel, clNone, False, clNone, False);
  Secondary := SecondaryTextColor(FBar.PanelColor);
  FScroll := Max(0, Min(FScroll, MaxScroll));
  C.ClipRect := Rect(Panel.Left, Panel.Top + 2, Panel.Right, Panel.Bottom - 2);
  C.Clipping := True;
  Y := Panel.Top + 8 - FScroll;
  for I := 0 to High(FBar.FItems) do
  begin
    if Y >= Panel.Bottom then
      Break;
    if Y + RowHeight <= Panel.Top then
    begin
      Inc(Y, RowHeight);
      Continue;
    end;
    Amount := HoverAmount(I, GetTickCount64);
    if Amount > 0.01 then
    begin
      { .hoverHighlight(cornerRadius: 6), faded in and out. }
      C.Brush.Style := bsSolid;
      C.Brush.Color := Blend(FBar.PanelColor, clWindowText, 0.08 * Amount);
      C.Pen.Style := psClear;
      C.RoundRect(Panel.Left + 6, Y, Panel.Right - 6, Y + RowHeight, 12, 12);
      C.Pen.Style := psSolid;
    end;
    X := Panel.Left + 6 + 8;
    FBar.DrawSymbol(C, 'xmark', X, Y + (RowHeight - 9) div 2, 9, Secondary);
    Inc(X, 9 + 8);
    DrawFileIcon(C, Rect(X, Y + 6, X + 18, Y + 24), FBar.FItems[I].Path,
      FBar.FItems[I].IsDirectory);
    Inc(X, 18 + 8);
    C.Brush.Style := bsClear;
    C.Font.Size := 13;
    C.Font.Style := [];
    SizeText := FormatFileSize(FBar.FItems[I].Size);
    C.Font.Color := Secondary;
    W := C.TextWidth(SizeText);
    C.TextOut(Panel.Right - 6 - 8 - W, Y + (RowHeight - C.TextHeight(SizeText)) div 2, SizeText);
    C.Font.Color := ColorToRGB(clWindowText);
    RowName := FBar.FItems[I].Name;
    Keep := CodePointCount(RowName);
    while (C.TextWidth(RowName) > Panel.Right - 6 - 8 - W - 12 - X) and (Keep > 4) do
    begin
      Dec(Keep);
      RowName := TruncateMiddle(FBar.FItems[I].Name, Keep);
    end;
    C.TextOut(X, Y + (RowHeight - C.TextHeight(RowName)) div 2, RowName);
    Inc(Y, RowHeight);
  end;
  { An overlay scroller showing the visible part of the list. }
  if MaxScroll > 0 then
  begin
    W := Panel.Bottom - Panel.Top - 12;
    Y := Max(24, W * (Panel.Bottom - Panel.Top) div (Length(FBar.FItems) * RowHeight + 16));
    X := Panel.Top + 6 + (W - Y) * FScroll div MaxScroll;
    C.Brush.Style := bsSolid;
    C.Brush.Color := Blend(FBar.PanelColor, clWindowText, 0.35);
    C.Pen.Style := psClear;
    C.RoundRect(Panel.Right - 9, X, Panel.Right - 4, X + Y, 5, 5);
    C.Pen.Style := psSolid;
  end;
  C.Clipping := False;
end;

function TCollectorOverlay.MaxScroll: Integer;
begin
  Result := Max(0, Length(FBar.FItems) * RowHeight + 16 - (ClientHeight - ShadowSpace));
end;

{ The row under Y, scroll included; -1 outside the rows. }
function TCollectorOverlay.RowAt(Y: Integer): Integer;
begin
  Result := -1;
  if (Y < 8) or (Y >= ClientHeight - ShadowSpace) then
    Exit;
  Result := (Y - 8 + FScroll) div RowHeight;
  if Result > High(FBar.FItems) then
    Result := -1;
end;

function TCollectorOverlay.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  NewScroll: Integer;
begin
  Result := True;
  if not FIsList then
    Exit(False);
  NewScroll := Max(0, Min(MaxScroll, FScroll - WheelDelta * RowHeight div 120));
  if NewScroll <> FScroll then
  begin
    FScroll := NewScroll;
    { Rows moved under the pointer: no fade carries over. }
    FHoverRows := nil;
    FHoverFades := nil;
    FHover := -1;
    SetHover(RowAt(ScreenToClient(Mouse.CursorPos).Y));
    Invalidate;
  end;
end;

{ Swift's remove button: the leading 31 pt of a row. }
const
  RemoveZone = 6 + 8 + 9 + 8;

procedure TCollectorOverlay.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  FPressRow := -1;
  FDragged := False;
  if (not FIsList) or (Button <> mbLeft) or (X < RemoveZone) then
    Exit;
  I := RowAt(Y);
  if I >= 0 then
  begin
    FPressRow := I;
    FPressX := X;
    FPressY := Y;
  end;
end;

procedure TCollectorOverlay.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  H: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FIsList then
    Exit;
  { DragGesture(minimumDistance: 4) on a CollectedRow. }
  if (FPressRow >= 0) and not FDragged and (ssLeft in Shift) and
    (Sqr(X - FPressX) + Sqr(Y - FPressY) >= 16) then
  begin
    FDragged := True;
    if Assigned(FBar.FOnDragOut) then
      FBar.FOnDragOut(FBar, Self, [FBar.FItems[FPressRow].Path]);
    Exit;
  end;
  FBar.ListHover(True);
  SetHover(RowAt(Y));
end;

procedure TCollectorOverlay.MouseLeave;
begin
  inherited MouseLeave;
  if not FIsList then
    Exit;
  SetHover(-1);
  FBar.ListHover(False);
end;

function TCollectorOverlay.HoverAmount(Row: Integer; NowMs: QWord): Double;
var
  I: Integer;
begin
  for I := 0 to High(FHoverRows) do
    if FHoverRows[I] = Row then
      Exit(ValueAt(FHoverFades[I], NowMs));
  Result := 0;
end;

function TCollectorOverlay.HoverMoving(NowMs: QWord): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FHoverFades) do
    if not AtRest(FHoverFades[I], NowMs) then
      Exit(True);
end;

procedure TCollectorOverlay.PruneHover(NowMs: QWord);
var
  I, N: Integer;
begin
  N := 0;
  for I := 0 to High(FHoverRows) do
    if not AtRest(FHoverFades[I], NowMs) or (FHoverFades[I].ToValue > 0) then
    begin
      FHoverRows[N] := FHoverRows[I];
      FHoverFades[N] := FHoverFades[I];
      Inc(N);
    end;
  SetLength(FHoverRows, N);
  SetLength(FHoverFades, N);
end;

procedure TCollectorOverlay.SetHover(Row: Integer);
var
  NowMs: QWord;
  Duration, I: Integer;
  Found: Boolean;
begin
  if Row = FHover then
    Exit;
  NowMs := GetTickCount64;
  if ReduceMotion then
    Duration := 0
  else
    Duration := 150;
  for I := 0 to High(FHoverRows) do
    if FHoverRows[I] = FHover then
      Retarget(FHoverFades[I], 0, NowMs, Duration, eaEaseInOut);
  FHover := Row;
  if Row >= 0 then
  begin
    Found := False;
    for I := 0 to High(FHoverRows) do
      if FHoverRows[I] = Row then
      begin
        Retarget(FHoverFades[I], 1, NowMs, Duration, eaEaseInOut);
        Found := True;
      end;
    if not Found then
    begin
      SetLength(FHoverRows, Length(FHoverRows) + 1);
      SetLength(FHoverFades, Length(FHoverFades) + 1);
      FHoverRows[High(FHoverRows)] := Row;
      FHoverFades[High(FHoverFades)] := AnimatedAt(0);
      Retarget(FHoverFades[High(FHoverFades)], 1, NowMs, Duration, eaEaseInOut);
    end;
  end;
  Invalidate;
  FBar.StartMotion;
end;

procedure TCollectorOverlay.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
var
  I: Integer;
begin
  Handled := True;
  if not FIsList then
    Exit;
  I := RowAt(MousePos.Y);
  if (I >= 0) and Assigned(FBar.FOnRowMenu) then
    FBar.FOnRowMenu(FBar, FBar.FItems[I].Path, ClientToScreen(MousePos));
end;

procedure TCollectorOverlay.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  FPressRow := -1;
  if (not FIsList) or (Button <> mbLeft) or FDragged then
    Exit;
  I := RowAt(Y);
  if (I >= 0) and (X < RemoveZone) and
    Assigned(FBar.FOnRemoveItem) then
    FBar.FOnRemoveItem(FBar, FBar.FItems[I].Path);
end;

{ ---- TCollectorBarView ---- }

constructor TCollectorBarView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FList := TCollectorOverlay.CreateFor(Self, True);
  FNoticePanel := TCollectorOverlay.CreateFor(Self, False);
  FCollapse := TTimer.Create(Self);
  FCollapse.Enabled := False;
  FCollapse.Interval := 160;
  FCollapse.OnTimer := @CollapseTick;
  FNoticeTimer := TTimer.Create(Self);
  FNoticeTimer.Enabled := False;
  FNoticeTimer.Interval := 3500;
  FNoticeTimer.OnTimer := @NoticeTick;
  FSpin := TTimer.Create(Self);
  FSpin.Enabled := False;
  FSpin.Interval := 100;
  FSpin.OnTimer := @SpinTick;
  UpdateHeight;
end;

destructor TCollectorBarView.Destroy;
begin
  FCollapse.Enabled := False;
  FNoticeTimer.Enabled := False;
  FSpin.Enabled := False;
  FreeAndNil(FMotion);
  inherited Destroy;
end;

procedure TCollectorBarView.SetParent(NewParent: TWinControl);
begin
  inherited SetParent(NewParent);
  FList.Parent := NewParent;
  FNoticePanel.Parent := NewParent;
end;

function TCollectorBarView.PanelColor: TColor;
begin
  { .regularMaterial over the window: a light, slightly greyed surface. }
  Result := Blend(clWindow, clWindowText, 0.06);
end;

procedure TCollectorBarView.DrawPanel(C: TCanvas; const R: TRect; Tint: TColor;
  HasTint: Boolean; BorderColor: TColor; HasBorder: Boolean; Amount: Double);
var
  Bg: TColor;
  I: Integer;
begin
  Bg := ColorToRGB(Parent.Color);
  { Shadow (black 0.18, radius 10, y 3), approximated by soft rings. }
  C.Pen.Style := psClear;
  C.Brush.Style := bsSolid;
  for I := 3 downto 1 do
  begin
    C.Brush.Color := Blend(Bg, clBlack, 0.05 * (4 - I) / 3);
    C.RoundRect(R.Left - I + 1, R.Top + 3 - I + 1, R.Right + I - 1, R.Bottom + 3 + I - 1,
      2 * Radius, 2 * Radius);
  end;
  C.Brush.Color := PanelColor;
  if HasTint then
    C.Brush.Color := Blend(PanelColor, Tint, 0.18 * Amount);
  C.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 2 * Radius, 2 * Radius);
  if HasBorder then
  begin
    C.Brush.Style := bsClear;
    C.Pen.Style := psSolid;
    C.Pen.Color := Blend(PanelColor, BorderColor, Amount);
    C.Pen.Width := 2;
    C.RoundRect(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1, 2 * Radius, 2 * Radius);
    C.Pen.Width := 1;
  end;
  C.Pen.Style := psSolid;
end;

procedure TCollectorBarView.DrawSymbol(C: TCanvas; const SymName: string; X, Y,
  Size: Integer; SymColor: TColor);
var
  Bmp: TBitmap;
begin
  Bmp := SystemSymbolBitmap(SymName, 2 * Size, ColorToRGB(SymColor));
  if Bmp = nil then
    Exit;
  try
    C.StretchDraw(Rect(X, Y, X + Size, Y + Size), Bmp);
  finally
    Bmp.Free;
  end;
end;

function TCollectorBarView.TotalBytes: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    Inc(Result, FItems[I].Size);
end;

procedure TCollectorBarView.UpdateHeight;
var
  H: Integer;
begin
  { Content heights of the Swift views at their fonts, plus padding. }
  case FPhase of
    cbDeleting: H := 52;
    cbIdle:
      if Length(FItems) > 0 then H := 34 else H := 20;
  else
    H := 20;
  end;
  H := H + 2 * PadV + ShadowSpace;
  if Height <> H then
    Height := H;
end;

procedure TCollectorBarView.Paint;
var
  C: TCanvas;
  Panel: TRect;
  Bg, Secondary, Ink, Accent: TColor;
  X, Y, W, MidY: Integer;
  S, Count: string;
  A: Double;
  I, Lit: Integer;
begin
  C := Canvas;
  Bg := ColorToRGB(Parent.Color);
  C.Brush.Style := bsSolid;
  C.Brush.Color := Bg;
  C.FillRect(ClientRect);
  Panel := Rect(0, 0, ClientWidth, ClientHeight - ShadowSpace);
  Accent := TintColorFor(cbTargeted);
  if ValueAt(FTint, GetTickCount64) > 0.001 then
    DrawPanel(C, Panel, FTintColor, True, FTintColor, True, ValueAt(FTint, GetTickCount64))
  else
    DrawPanel(C, Panel, clNone, False, clNone, False);
  Secondary := SecondaryTextColor(PanelColor);
  Ink := ColorToRGB(clWindowText);
  C.Brush.Style := bsClear;
  X := Panel.Left + PadH;
  MidY := (Panel.Top + Panel.Bottom) div 2;
  FDeleteRect := Rect(0, 0, 0, 0);

  case FPhase of
    cbRejecting:
      begin
        { rejectionView: nosign + reason, callout semibold, red. }
        DrawSymbol(C, 'nosign', X, MidY - 7, 14, SystemRed);
        C.Font.Size := CalloutSize;
        C.Font.Style := [fsBold];
        C.Font.Color := SystemRed;
        S := FRejectReason;
        if S = '' then
          S := 'This item can’t be deleted';
        C.TextOut(X + 22, MidY - C.TextHeight(S) div 2, S);
      end;
    cbTargeted, cbIdle:
      if (FPhase = cbTargeted) or (Length(FItems) = 0) then
      begin
        { hintView: centred symbol + text; accent and semibold while
          targeted. }
        C.Font.Size := CalloutSize;
        if FPhase = cbTargeted then
        begin
          C.Font.Style := [fsBold];
          C.Font.Color := Accent;
          S := 'Release to collect';
        end
        else
        begin
          C.Font.Style := [];
          C.Font.Color := Secondary;
          S := 'Drag files here to collect them for deletion';
        end;
        W := 14 + 8 + C.TextWidth(S);
        X := (Panel.Left + Panel.Right - W) div 2;
        if FPhase = cbTargeted then
          DrawSymbol(C, 'arrow.down.circle.fill', X, MidY - 7, 14, Accent)
        else
          DrawSymbol(C, 'arrow.down.circle.dotted', X, MidY - 7, 14, Secondary);
        C.TextOut(X + 22, MidY - C.TextHeight(S) div 2, S);
      end
      else
      begin
        { footerRow: total (headline, monospaced digits) over 'N items
          collected' (caption, secondary); red Delete capsule. }
        C.Font.Size := HeadlineSize;
        C.Font.Style := [fsBold];
        C.Font.Color := Ink;
        Y := Panel.Top + PadV;
        DrawRolling(C, X, Y, FormatFileSize(TotalBytes), FTotalRoll);
        Inc(Y, C.TextHeight('Ag') + 1);
        C.Font.Size := CaptionSize;
        C.Font.Style := [];
        C.Font.Color := Secondary;
        if Length(FItems) = 1 then
          Count := '1 item collected'
        else
          Count := Format('%d items collected', [Length(FItems)]);
        C.TextOut(X, Y, Count);
        C.Font.Size := 13;
        C.Font.Style := [fsBold];
        W := C.TextWidth('Delete') + 32;
        FDeleteRect := Rect(Panel.Right - PadH - W, MidY - 13, Panel.Right - PadH, MidY + 13);
        C.Brush.Style := bsSolid;
        C.Brush.Color := SystemRed;
        C.Pen.Style := psClear;
        C.RoundRect(FDeleteRect, 26, 26);
        C.Pen.Style := psSolid;
        C.Brush.Style := bsClear;
        C.Font.Color := clWhite;
        C.TextOut(FDeleteRect.Left + 16, MidY - C.TextHeight('Delete') div 2, 'Delete');
      end;
    cbDeleting:
      begin
        { deletingView: spinner, 'Deleting <name>…' (medium), 'Freed X ·
          n of N' (caption), then a small linear bar. }
        Y := Panel.Top + PadV;
        Lit := ((GetTickCount64 - FSpinStart) div 100) mod 8;
        C.Pen.Width := 2;
        for I := 0 to 7 do
        begin
          A := I * Pi / 4;
          if I = Lit then
            C.Pen.Color := Secondary
          else
            C.Pen.Color := Blend(Secondary, PanelColor, 0.6);
          C.Line(X + 8 + Round(Cos(A) * 3), Y + 12 + Round(Sin(A) * 3),
            X + 8 + Round(Cos(A) * 7), Y + 12 + Round(Sin(A) * 7));
        end;
        C.Pen.Width := 1;
        C.Font.Size := 13;
        C.Font.Style := [];
        C.Font.Color := Ink;
        if FDeletingName <> '' then
          S := 'Deleting ' + FDeletingName + '…'
        else
          S := 'Deleting…';
        C.TextOut(X + 26, Y, S);
        C.Font.Size := CaptionSize;
        C.Font.Color := Secondary;
        W := X + 26;
        C.TextOut(W, Y + 17, 'Freed ');
        Inc(W, C.TextWidth('Freed '));
        C.Font.Style := [fsBold];
        C.Font.Color := Ink;
        S := FormatFileSize(FFreedBytes);
        DrawRolling(C, W, Y + 17, S, FFreedRoll);
        Inc(W, C.TextWidth(S));
        C.Font.Style := [];
        C.Font.Color := Secondary;
        C.TextOut(W, Y + 17, Format(' · %d of %d', [FCompleted, FTotal]));
        if FTotal > 0 then
        begin
          Y := Panel.Bottom - PadV - 4;
          C.Brush.Style := bsSolid;
          C.Pen.Style := psClear;
          C.Brush.Color := Blend(PanelColor, clWindowText, 0.15);
          C.RoundRect(X, Y, Panel.Right - PadH, Y + 4, 4, 4);
          W := Round((Panel.Right - PadH - X) * Min(FCompleted, FTotal) / FTotal);
          if W > 0 then
          begin
            C.Brush.Color := Accent;
            C.RoundRect(X, Y, X + W, Y + 4, 4, 4);
          end;
          C.Pen.Style := psSolid;
        end;
      end;
    cbDone:
      begin
        { doneView: green checkmark, 'Freed ' + bytes (semibold), orange
          failures. }
        DrawSymbol(C, 'checkmark.circle.fill', X, MidY - 7, 14, SystemGreen);
        Inc(X, 22);
        C.Font.Size := CalloutSize;
        C.Font.Style := [];
        C.Font.Color := Secondary;
        C.TextOut(X, MidY - C.TextHeight('F') div 2, 'Freed ');
        Inc(X, C.TextWidth('Freed '));
        C.Font.Style := [fsBold];
        C.Font.Color := Ink;
        S := FormatFileSize(FDoneFreed);
        C.TextOut(X, MidY - C.TextHeight(S) div 2, S);
        Inc(X, C.TextWidth(S));
        if FDoneFailures > 0 then
        begin
          C.Font.Size := CaptionSize;
          C.Font.Style := [];
          C.Font.Color := SystemOrange;
          S := Format(' · %d couldn’t be removed', [FDoneFailures]);
          C.TextOut(X, MidY - C.TextHeight(S) div 2, S);
        end;
      end;
  end;
end;

procedure TCollectorBarView.Resize;
begin
  inherited Resize;
  UpdateOverlays;
end;

function TCollectorBarView.WantsList: Boolean;
begin
  { wantsList: idle, something staged, footer or list hovered. }
  Result := (FPhase = cbIdle) and (Length(FItems) > 0) and not FDraggingOut and
    (FForceList or FFooterHovered or FListHovered);
end;

{ CollectorBar's list and notice: in and out with a 0.3 s spring, fading
  while they slide from (or to) the footer; Reduce Motion swaps them at
  once. }
procedure TCollectorBarView.ShowOverlay(O: TCollectorOverlay; const R: TRect);
var
  NowMs: QWord;
  Duration: Integer;
begin
  NowMs := GetTickCount64;
  if ReduceMotion then
    Duration := 0
  else
    Duration := 300;
  O.FRestTop := R.Top;
  if not O.Visible then
  begin
    O.FShown := AnimatedAt(0);
    O.SetBounds(R.Left, R.Top + (R.Bottom - R.Top), R.Right - R.Left, R.Bottom - R.Top);
    O.Visible := True;
    SetControlAlpha(O, 0);
  end
  else
    O.SetBounds(R.Left, O.Top, R.Right - R.Left, R.Bottom - R.Top);
  O.BringToFront;
  Retarget(O.FShown, 1, NowMs, Duration, eaSpring);
  PlaceOverlay(O, NowMs);
  if FMotion = nil then
    FMotion := TFrameClock.Create(Self, @MotionFrame);
  FMotion.Start;
end;

procedure TCollectorBarView.HideOverlay(O: TCollectorOverlay);
var
  Duration: Integer;
begin
  if (O = nil) or not O.Visible then
    Exit;
  if ReduceMotion then
    Duration := 0
  else
    Duration := 300;
  Retarget(O.FShown, 0, GetTickCount64, Duration, eaSpring);
  if FMotion = nil then
    FMotion := TFrameClock.Create(Self, @MotionFrame);
  FMotion.Start;
  MotionFrame(nil);
end;

procedure TCollectorBarView.PlaceOverlay(O: TCollectorOverlay; NowMs: QWord);
var
  P: Double;
begin
  P := ValueAt(O.FShown, NowMs);
  { Automation: OPENDISK_DEBUG_MOTION=1 logs each frame of the transition. }
  if GetEnvironmentVariable('OPENDISK_DEBUG_MOTION') = '1' then
  begin
    WriteLn(Format('motion %d ms: shown %.3f top %d (rest %d)',
      [NowMs - O.FShown.StartMs, P, O.FRestTop + Round((1 - P) * O.Height), O.FRestTop]));
    Flush(Output);
  end;
  SetControlAlpha(O, P);
  O.Top := O.FRestTop + Round((1 - P) * O.Height);
  { Gone: hidden for real, opaque again for its next showing. }
  if AtRest(O.FShown, NowMs) and (O.FShown.ToValue = 0) then
  begin
    O.Visible := False;
    O.Top := O.FRestTop;
    SetControlAlpha(O, 1);
  end;
end;

procedure TCollectorBarView.StartRoll(var Roll: TRollingText; const OldText: string;
  Up: Boolean; DurationMs: Integer; Easing: TEasing);
begin
  if ReduceMotion then
    Exit;
  Roll.OldText := OldText;
  Roll.Up := Up;
  Roll.Anim := AnimatedAt(0);
  Retarget(Roll.Anim, 1, GetTickCount64, DurationMs, Easing);
  StartMotion;
end;

{ numericText: while rolling, the old text leaves its line (up when the
  value grew, down when it shrank) as the new one comes in, both clipped
  to the line. }
procedure TCollectorBarView.DrawRolling(C: TCanvas; X, Y: Integer;
  const NewText: string; const Roll: TRollingText);
var
  P: Double;
  H, Shift, Dir: Integer;
  Line: TRect;
begin
  P := ValueAt(Roll.Anim, GetTickCount64);
  if (P >= 1) or (Roll.OldText = '') then
  begin
    C.TextOut(X, Y, NewText);
    Exit;
  end;
  H := C.TextHeight('Ag');
  Line := Rect(X, Y, X + Max(C.TextWidth(NewText), C.TextWidth(Roll.OldText)) + 2, Y + H);
  if GetEnvironmentVariable('OPENDISK_DEBUG_MOTION') = '1' then
  begin
    WriteLn(Format('roll %.3f: "%s" -> "%s"', [P, Roll.OldText, NewText]));
    Flush(Output);
  end;
  if Roll.Up then
    Dir := -1
  else
    Dir := 1;
  Shift := Round(P * H);
  C.TextRect(Line, X, Y + Dir * Shift, Roll.OldText);
  C.TextRect(Line, X, Y + Dir * Shift - Dir * H, NewText);
end;

procedure TCollectorBarView.StartMotion;
begin
  if FMotion = nil then
    FMotion := TFrameClock.Create(Self, @MotionFrame);
  FMotion.Start;
end;

procedure TCollectorBarView.MotionFrame(Sender: TObject);
var
  NowMs: QWord;
  Moving: Boolean;
begin
  NowMs := GetTickCount64;
  Moving := not AtRest(FTint, NowMs) or not AtRest(FTotalRoll.Anim, NowMs) or
    not AtRest(FFreedRoll.Anim, NowMs);
  if Moving or (FTint.StartMs + QWord(FTint.DurationMs) + 50 > NowMs) or
    (FTotalRoll.Anim.StartMs + QWord(FTotalRoll.Anim.DurationMs) + 50 > NowMs) or
    (FFreedRoll.Anim.StartMs + QWord(FFreedRoll.Anim.DurationMs) + 50 > NowMs) then
    Invalidate;
  if (FList <> nil) and FList.Visible then
  begin
    PlaceOverlay(FList, NowMs);
    Moving := Moving or not AtRest(FList.FShown, NowMs);
    if Length(FList.FHoverFades) > 0 then
    begin
      { The settling frame is drawn too; then faded-out rows are dropped. }
      FList.Invalidate;
      Moving := Moving or FList.HoverMoving(NowMs);
      FList.PruneHover(NowMs);
    end;
  end;
  if (FNoticePanel <> nil) and FNoticePanel.Visible then
  begin
    PlaceOverlay(FNoticePanel, NowMs);
    Moving := Moving or not AtRest(FNoticePanel.FShown, NowMs);
  end;
  if not Moving and (FMotion <> nil) then
    FMotion.Stop;
end;

procedure TCollectorBarView.UpdateOverlays;
var
  H, Bottom: Integer;
begin
  if Parent = nil then
    Exit;
  Bottom := Top - ListGap + ShadowSpace;
  if WantsList then
  begin
    FCollapse.Enabled := False;
    { listHeight = min(600, count * 30 + 16), within the room above. }
    H := Min(Min(600, Length(FItems) * RowHeight + 16), Bottom - ShadowSpace - 8) + ShadowSpace;
    ShowOverlay(FList, Rect(Left, Bottom - H, Left + Width, Bottom));
    FList.Invalidate;
  end;
  if FNotice <> '' then
  begin
    H := 44 + ShadowSpace;
    ShowOverlay(FNoticePanel, Rect(Left, Bottom - H, Left + Width, Bottom));
    FNoticePanel.Invalidate;
  end
  else
    HideOverlay(FNoticePanel);
end;

procedure TCollectorBarView.ListHover(Value: Boolean);
begin
  FListHovered := Value;
  if WantsList then
    UpdateOverlays
  else
    FCollapse.Enabled := True;
end;

procedure TCollectorBarView.CollapseTick(Sender: TObject);
begin
  FCollapse.Enabled := False;
  if not WantsList then
    HideOverlay(FList);
end;

procedure TCollectorBarView.NoticeTick(Sender: TObject);
begin
  FNoticeTimer.Enabled := False;
  FNotice := '';
  UpdateOverlays;
end;

procedure TCollectorBarView.SpinTick(Sender: TObject);
begin
  if IsVisible then
    Invalidate;
end;

procedure TCollectorBarView.MouseEnter;
begin
  inherited MouseEnter;
  FFooterHovered := True;
  if WantsList then
    UpdateOverlays;
end;

procedure TCollectorBarView.MouseLeave;
begin
  inherited MouseLeave;
  FFooterHovered := False;
  if not WantsList then
    FCollapse.Enabled := True;
end;

procedure TCollectorBarView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  { The total and count drag every staged item; the button does not. }
  FPressed := (Button = mbLeft) and (FPhase = cbIdle) and (Length(FItems) > 0) and
    not PtInRect(FDeleteRect, Point(X, Y));
  FDragged := False;
  FPressX := X;
  FPressY := Y;
end;

procedure TCollectorBarView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Paths: array of string;
  I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FPressed and not FDragged and (ssLeft in Shift) and
    (Sqr(X - FPressX) + Sqr(Y - FPressY) >= 16) then
  begin
    FDragged := True;
    SetLength(Paths, Length(FItems));
    for I := 0 to High(FItems) do
      Paths[I] := FItems[I].Path;
    if Assigned(FOnDragOut) then
      FOnDragOut(Self, Self, Paths);
  end;
end;

procedure TCollectorBarView.SetDraggingOut(Value: Boolean);
begin
  if FDraggingOut = Value then
    Exit;
  FDraggingOut := Value;
  { The list disappears while its items are dragged out. }
  if Value and (FList <> nil) then
    HideOverlay(FList);
  UpdateOverlays;
end;

procedure TCollectorBarView.DragFinished;
begin
  FPressed := False;
  FDragged := False;
  if FList <> nil then
  begin
    FList.FPressRow := -1;
    FList.FDragged := False;
  end;
end;

function TCollectorBarView.InKeepZone(const ScreenPt: TPoint): Boolean;
begin
  Result := PtInRect(ClientRect, ScreenToClient(ScreenPt)) or
    ((FList <> nil) and FList.Visible and
     PtInRect(FList.ClientRect, FList.ScreenToClient(ScreenPt)));
end;

procedure TCollectorBarView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FPressed := False;
  if (Button = mbLeft) and not FDragged and PtInRect(FDeleteRect, Point(X, Y)) and
    Assigned(FOnDeleteClick) then
    FOnDeleteClick(Self);
end;

procedure TCollectorBarView.SetItems(const Items: TCollectorItems);
var
  OldTotal: Int64;
begin
  OldTotal := TotalBytes;
  FItems := Copy(Items);
  if (FormatFileSize(OldTotal) <> FormatFileSize(TotalBytes)) and
    (OldTotal > 0) and (TotalBytes > 0) then
    StartRoll(FTotalRoll, FormatFileSize(OldTotal), TotalBytes > OldTotal, 300, eaSpring);
  UpdateHeight;
  if WantsList then
    UpdateOverlays
  else
    HideOverlay(FList);
  Invalidate;
end;

function TCollectorBarView.TintColorFor(Phase: TCollectorPhase): TColor;
begin
  if Phase = cbRejecting then
    Result := SystemRed
  else
    { .accentColor, not the (inactive-pale) selection colour. }
    Result := AccentColor(ColorToRGB(clHighlight));
end;

procedure TCollectorBarView.SetPhase(Phase: TCollectorPhase; const RejectReason: string);
var
  Duration: Integer;
begin
  if Phase in [cbTargeted, cbRejecting] then
    FTintColor := TintColorFor(Phase);
  if ReduceMotion then
    Duration := 0
  else
    Duration := 150;
  if Phase in [cbTargeted, cbRejecting] then
    Retarget(FTint, 1, GetTickCount64, Duration, eaEaseInOut)
  else
    Retarget(FTint, 0, GetTickCount64, Duration, eaEaseInOut);
  if not AtRest(FTint, GetTickCount64) then
  begin
    if FMotion = nil then
      FMotion := TFrameClock.Create(Self, @MotionFrame);
    FMotion.Start;
  end;
  FPhase := Phase;
  FRejectReason := RejectReason;
  FSpin.Enabled := Phase = cbDeleting;
  if Phase = cbDeleting then
    FSpinStart := GetTickCount64;
  UpdateHeight;
  if not WantsList then
    HideOverlay(FList);
  Invalidate;
end;

procedure TCollectorBarView.SetDeletionProgress(const CurrentName: string;
  FreedBytes: Int64; Completed, Total: Integer);
begin
  FDeletingName := CurrentName;
  if (FreedBytes > FFreedBytes) and (FFreedBytes > 0) and
    (FormatFileSize(FreedBytes) <> FormatFileSize(FFreedBytes)) then
    StartRoll(FFreedRoll, FormatFileSize(FFreedBytes), True, 250, eaSnappy);
  FFreedBytes := FreedBytes;
  FCompleted := Completed;
  FTotal := Total;
  Invalidate;
end;

procedure TCollectorBarView.SetDoneResult(FreedBytes: Int64; Failures: Integer);
begin
  FDoneFreed := FreedBytes;
  FDoneFailures := Failures;
  Invalidate;
end;

procedure TCollectorBarView.ShowNotice(const NoticeText: string);
begin
  FNotice := NoticeText;
  FNoticeTimer.Enabled := False;
  FNoticeTimer.Enabled := NoticeText <> '';
  UpdateOverlays;
end;

procedure TCollectorBarView.SetListVisible(Value: Boolean);
begin
  FForceList := Value;
  UpdateOverlays;
  if not WantsList then
    HideOverlay(FList);
end;

end.
