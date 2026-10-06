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
  Classes, SysUtils, Math, Graphics, Controls, ExtCtrls, Types;

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

  TCollectorBarView = class;

  { A floating rounded panel above the footer: the staged list or the
    notice. }
  TCollectorOverlay = class(TCustomControl)
  private
    FBar: TCollectorBarView;
    FIsList: Boolean;
    FHover: Integer;
  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
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
    procedure CollapseTick(Sender: TObject);
    procedure NoticeTick(Sender: TObject);
    procedure SpinTick(Sender: TObject);
    procedure UpdateOverlays;
    procedure UpdateHeight;
    function WantsList: Boolean;
    function TotalBytes: Int64;
    function PanelColor: TColor;
    procedure DrawPanel(C: TCanvas; const R: TRect; Tint: TColor; HasTint: Boolean;
      BorderColor: TColor; HasBorder: Boolean);
    procedure DrawSymbol(C: TCanvas; const SymName: string; X, Y, Size: Integer; SymColor: TColor);
    procedure ListHover(Value: Boolean);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure SetParent(NewParent: TWinControl); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
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
  end;

implementation

uses
  LCLType, LCLIntf, PlatformImages, GuiColors, Formatters, TextTrim;

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
  CalloutSize = 12;
  HeadlineSize = 13;
  CaptionSize = 10;

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
  Y := Panel.Top + 8;
  for I := 0 to High(FBar.FItems) do
  begin
    if Y + RowHeight > Panel.Bottom then
      Break;
    if I = FHover then
    begin
      { .hoverHighlight(cornerRadius: 6) }
      C.Brush.Style := bsSolid;
      C.Brush.Color := Blend(FBar.PanelColor, clWindowText, 0.08);
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
end;

procedure TCollectorOverlay.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  H: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FIsList then
    Exit;
  FBar.ListHover(True);
  H := (Y - 8) div RowHeight;
  if (Y < 8) or (H > High(FBar.FItems)) then
    H := -1;
  if H <> FHover then
  begin
    FHover := H;
    Invalidate;
  end;
end;

procedure TCollectorOverlay.MouseLeave;
begin
  inherited MouseLeave;
  if not FIsList then
    Exit;
  FHover := -1;
  Invalidate;
  FBar.ListHover(False);
end;

procedure TCollectorOverlay.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (not FIsList) or (Button <> mbLeft) then
    Exit;
  I := (Y - 8) div RowHeight;
  { The remove button: the leading 30 pt of a row. }
  if (Y >= 8) and (I >= 0) and (I <= High(FBar.FItems)) and (X < 6 + 8 + 9 + 8) and
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
  HasTint: Boolean; BorderColor: TColor; HasBorder: Boolean);
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
    C.Brush.Color := Blend(PanelColor, Tint, 0.18);
  C.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 2 * Radius, 2 * Radius);
  if HasBorder then
  begin
    C.Brush.Style := bsClear;
    C.Pen.Style := psSolid;
    C.Pen.Color := ColorToRGB(BorderColor);
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
  Accent := ColorToRGB(clHighlight);
  case FPhase of
    cbTargeted: DrawPanel(C, Panel, Accent, True, Accent, True);
    cbRejecting: DrawPanel(C, Panel, SystemRed, True, SystemRed, True);
  else
    DrawPanel(C, Panel, clNone, False, clNone, False);
  end;
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
        C.TextOut(X, Y, FormatFileSize(TotalBytes));
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
        C.TextOut(W, Y + 17, S);
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
  Result := (FPhase = cbIdle) and (Length(FItems) > 0) and
    (FForceList or FFooterHovered or FListHovered);
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
    H := Min(600, Length(FItems) * RowHeight + 16) + ShadowSpace;
    FList.SetBounds(Left, Bottom - H, Width, H);
    FList.Visible := True;
    FList.BringToFront;
    FList.Invalidate;
  end;
  if FNotice <> '' then
  begin
    H := 44 + ShadowSpace;
    FNoticePanel.SetBounds(Left, Bottom - H, Width, H);
    FNoticePanel.Visible := True;
    FNoticePanel.BringToFront;
    FNoticePanel.Invalidate;
  end
  else
    FNoticePanel.Visible := False;
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
    FList.Visible := False;
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

procedure TCollectorBarView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and PtInRect(FDeleteRect, Point(X, Y)) and
    Assigned(FOnDeleteClick) then
    FOnDeleteClick(Self);
end;

procedure TCollectorBarView.SetItems(const Items: TCollectorItems);
begin
  FItems := Copy(Items);
  UpdateHeight;
  if WantsList then
    UpdateOverlays
  else
    FList.Visible := False;
  Invalidate;
end;

procedure TCollectorBarView.SetPhase(Phase: TCollectorPhase; const RejectReason: string);
begin
  FPhase := Phase;
  FRejectReason := RejectReason;
  FSpin.Enabled := Phase = cbDeleting;
  if Phase = cbDeleting then
    FSpinStart := GetTickCount64;
  UpdateHeight;
  if not WantsList then
    FList.Visible := False;
  Invalidate;
end;

procedure TCollectorBarView.SetDeletionProgress(const CurrentName: string;
  FreedBytes: Int64; Completed, Total: Integer);
begin
  FDeletingName := CurrentName;
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
    FList.Visible := False;
end;

end.
