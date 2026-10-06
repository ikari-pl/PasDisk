{ ScanStatusBar — the analysis window's bottom bar.

  Port of Views/Components/ScanStatusBar.swift. A divider, then while
  scanning a small linear progress bar (indeterminate when the fraction
  is unknown), then one footnote row: on the left a mini spinner and the
  scan status (or the finished duration); on the right the volume
  capacity readout (bar + 'X available of Y', with a hint listing used /
  available / total / purgeable) and the displayed totals, '<bytes>' in
  semibold monospaced digits followed by '· N items'.

  Changing values repaint only when they differ. A timer runs only while
  scanning, for the spinner and the indeterminate bar. }

unit ScanStatusBar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Graphics, Controls, ExtCtrls, Types;

type
  TScanStatusPhase = (sspScanning, sspCheckingChanges);

  TScanStatusBar = class(TCustomControl)
  private
    FScanning: Boolean;
    FPhase: TScanStatusPhase;
    FProgress: Double;          { < 0: unknown }
    FScannedBytes: Int64;
    FItemsScanned: Integer;
    FScanStart: TDateTime;      { 0: unknown }
    FDuration: Double;          { seconds; 0: none to show }
    FTotalBytes: Int64;
    FItemCount: Integer;
    FHasCapacity: Boolean;
    FCapTotal, FCapAvailable, FCapPurgeable: Int64;
    { What VoiceOver was last told, to rebuild only on a change. }
    FAccessibleKey: string;
    FTimer: TTimer;
    FAnimStart: QWord;
    procedure UpdateAccessibility(const LeftText: string; const LeftR: TRect;
      const CapR: TRect; const TotalText: string; const TotalR: TRect);
    procedure Tick(Sender: TObject);
    procedure UpdateAnimation;
    procedure UpdateHeight;
    function ScanStatusText: string;
    function RateText: string;
    function TabularWidth(const S: string): Integer;
    procedure DrawTabular(X, Y: Integer; const S: string);
    procedure DrawLinearBar(const R: TRect; Fraction: Double);
    procedure DrawSpinner(CX, CY: Integer);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Scan in progress (ScanStatusBar.swift:15-24, 38-51). Progress < 0
      means unknown; ScanStart 0 hides the files/sec rate. }
    procedure SetScanning(ScannedBytes: Int64; ItemsScanned: Integer;
      Phase: TScanStatusPhase; Progress: Double = -1; ScanStart: TDateTime = 0);
    { Totals of the displayed folder, shown in every state (:65-71). }
    procedure SetTotals(TotalBytes: Int64; ItemCount: Integer);
    { Scan done; Duration > 0 shows 'Scanned in …' (:52-54). }
    procedure SetFinished(TotalBytes: Int64; ItemCount: Integer; Duration: Double);
    procedure SetVolumeCapacity(TotalBytes, AvailableBytes: Int64;
      PurgeableBytes: Int64 = 0);
    procedure ClearVolumeCapacity;
  end;

implementation

uses
  LCLType, LCLIntf, GuiColors, Formatters, PlatformLocale, DesignTokens, PlatformChartAccessibility;

const
  FootnoteSize = 10;
  FootnoteLine = 13;
  PadH = 16;
  PadV = 6;
  Spacing = 6;
  MinSpacer = 12;
  CapacityBarWidth = 96;
  CapacityGap = 8;
  ProgressHeight = 4;
  ProgressTop = 6;
  SpinnerSize = 10;

constructor TScanStatusBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  { .background(.bar): the window chrome colour. }
  ParentColor := False;
  Color := clBtnFace;
  FProgress := -1;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 33;
  FTimer.OnTimer := @Tick;
  ShowHint := True;
  UpdateHeight;
end;

destructor TScanStatusBar.Destroy;
begin
  FTimer.Enabled := False;
  inherited Destroy;
end;

procedure TScanStatusBar.UpdateHeight;
var
  H: Integer;
begin
  { A footnote line is 13 pt; no canvas is needed (none exists before the
    control has a parent). }
  H := 1 + PadV + FootnoteLine + PadV;
  if FScanning then
    Inc(H, ProgressTop + ProgressHeight);
  if Height <> H then
    Height := H;
end;

procedure TScanStatusBar.UpdateAnimation;
begin
  if FScanning <> FTimer.Enabled then
  begin
    FTimer.Enabled := FScanning;
    FAnimStart := GetTickCount64;
  end;
end;

procedure TScanStatusBar.Tick(Sender: TObject);
begin
  if not IsVisible then
    Exit;
  Invalidate;
end;

procedure TScanStatusBar.SetScanning(ScannedBytes: Int64; ItemsScanned: Integer;
  Phase: TScanStatusPhase; Progress: Double; ScanStart: TDateTime);
begin
  if FScanning and (FScannedBytes = ScannedBytes) and
    (FItemsScanned = ItemsScanned) and (FPhase = Phase) and
    (FProgress = Progress) and (FScanStart = ScanStart) then
    Exit;
  FScanning := True;
  FScannedBytes := ScannedBytes;
  FItemsScanned := ItemsScanned;
  FPhase := Phase;
  FProgress := Progress;
  FScanStart := ScanStart;
  UpdateHeight;
  UpdateAnimation;
  Invalidate;
end;

procedure TScanStatusBar.SetTotals(TotalBytes: Int64; ItemCount: Integer);
begin
  if (FTotalBytes = TotalBytes) and (FItemCount = ItemCount) then
    Exit;
  FTotalBytes := TotalBytes;
  FItemCount := ItemCount;
  Invalidate;
end;

procedure TScanStatusBar.SetFinished(TotalBytes: Int64; ItemCount: Integer;
  Duration: Double);
begin
  if (not FScanning) and (FDuration = Duration) and (FTotalBytes = TotalBytes) and
    (FItemCount = ItemCount) then
    Exit;
  FScanning := False;
  FDuration := Duration;
  FTotalBytes := TotalBytes;
  FItemCount := ItemCount;
  UpdateHeight;
  UpdateAnimation;
  Invalidate;
end;

procedure TScanStatusBar.SetVolumeCapacity(TotalBytes, AvailableBytes: Int64;
  PurgeableBytes: Int64);
var
  Used, Avail, Total: string;
begin
  if FHasCapacity and (FCapTotal = TotalBytes) and (FCapAvailable = AvailableBytes) and
    (FCapPurgeable = PurgeableBytes) then
    Exit;
  FHasCapacity := True;
  FCapTotal := TotalBytes;
  FCapAvailable := AvailableBytes;
  FCapPurgeable := PurgeableBytes;
  { ScanStatusBar.swift capacityHelp (:101-111). }
  Used := FormatFileSize(TotalBytes - AvailableBytes);
  Avail := FormatFileSize(AvailableBytes);
  Total := FormatFileSize(TotalBytes);
  Hint := 'Used: ' + Used + LineEnding + 'Available: ' + Avail + LineEnding +
    'Total: ' + Total;
  if PurgeableBytes > 0 then
    Hint := Hint + LineEnding + 'Available includes ' + FormatFileSize(PurgeableBytes) +
      ' of purgeable space, such as local Time Machine snapshots, that macOS ' +
      'frees automatically when needed.';
  Invalidate;
end;

procedure TScanStatusBar.ClearVolumeCapacity;
begin
  if not FHasCapacity then
    Exit;
  FHasCapacity := False;
  Hint := '';
  Invalidate;
end;

var
  { The user's grouping separator (Int.formatted()), read once. }
  GroupSep, DecimalSep: string;

function Grouped(Value: Int64): string;
var
  Digits: string;
  I, Count: Integer;
begin
  { Int.formatted(): grouping with the locale separator. }
  Digits := IntToStr(Abs(Value));
  Result := '';
  Count := 0;
  for I := Length(Digits) downto 1 do
  begin
    if (Count > 0) and (Count mod 3 = 0) then
      Result := GroupSep + Result;
    Result := Digits[I] + Result;
    Inc(Count);
  end;
  if Value < 0 then
    Result := '-' + Result;
end;

function TScanStatusBar.ScanStatusText: string;
begin
  if FItemsScanned > 0 then
    Result := 'Scanning: ' + FormatFileSize(FScannedBytes) + ' (' +
      Grouped(FItemsScanned) + ' items)'
  else if FPhase = sspCheckingChanges then
    Result := 'Checking what changed since the last scan…'
  else
    Result := 'Scanning…';
end;

function TScanStatusBar.RateText: string;
var
  Elapsed: Double;
begin
  Result := '';
  if (FScanStart = 0) or (FItemsScanned <= 0) then
    Exit;
  Elapsed := (Now - FScanStart) * 86400;
  if Elapsed <= 0 then
    Exit;
  Result := '· ' + Grouped(Trunc(FItemsScanned / Elapsed)) + ' files/sec';
end;

{ Monospaced digits: every digit takes the widest digit's advance, other
  characters their own (SwiftUI .monospacedDigit()). }
function TScanStatusBar.TabularWidth(const S: string): Integer;
var
  I, J, DigitW: Integer;
begin
  DigitW := Canvas.TextWidth('0');
  for I := 1 to 9 do
    DigitW := Max(DigitW, Canvas.TextWidth(Chr(Ord('0') + I)));
  Result := 0;
  I := 1;
  while I <= Length(S) do
    if S[I] in ['0'..'9'] then
    begin
      Inc(Result, DigitW);
      Inc(I);
    end
    else
    begin
      { A run of non-digits keeps its own kerning. }
      J := I;
      while (J <= Length(S)) and not (S[J] in ['0'..'9']) do
        Inc(J);
      Inc(Result, Canvas.TextWidth(Copy(S, I, J - I)));
      I := J;
    end;
end;

procedure TScanStatusBar.DrawTabular(X, Y: Integer; const S: string);
var
  I, J, DigitW: Integer;
begin
  DigitW := Canvas.TextWidth('0');
  for I := 1 to 9 do
    DigitW := Max(DigitW, Canvas.TextWidth(Chr(Ord('0') + I)));
  I := 1;
  while I <= Length(S) do
    if S[I] in ['0'..'9'] then
    begin
      Canvas.TextOut(X + (DigitW - Canvas.TextWidth(S[I])) div 2, Y, S[I]);
      Inc(X, DigitW);
      Inc(I);
    end
    else
    begin
      J := I;
      while (J <= Length(S)) and not (S[J] in ['0'..'9']) do
        Inc(J);
      Canvas.TextOut(X, Y, Copy(S, I, J - I));
      Inc(X, Canvas.TextWidth(Copy(S, I, J - I)));
      I := J;
    end;
end;

{ ProgressView(.linear, .small): rounded track, accent fill; Fraction < 0
  is indeterminate (a sliding segment). }
procedure TScanStatusBar.DrawLinearBar(const R: TRect; Fraction: Double);
var
  Fill: TRect;
  W, Seg, Pos: Integer;
  T: Double;
begin
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ColorToRGB(clBtnShadow);
  Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, R.Bottom - R.Top, R.Bottom - R.Top);
  W := R.Right - R.Left;
  Fill := R;
  if Fraction < 0 then
  begin
    Seg := W div 4;
    T := ((GetTickCount64 - FAnimStart) mod 1200) / 1200;
    Pos := Round((W + Seg) * T) - Seg;
    Fill.Left := R.Left + Max(0, Pos);
    Fill.Right := R.Left + Min(W, Pos + Seg);
  end
  else
    Fill.Right := R.Left + Round(W * Min(1, Max(0, Fraction)));
  if Fill.Right > Fill.Left then
  begin
    Canvas.Brush.Color := ColorToRGB(clHighlight);
    Canvas.RoundRect(Fill.Left, Fill.Top, Fill.Right, Fill.Bottom,
      R.Bottom - R.Top, R.Bottom - R.Top);
  end;
  Canvas.Pen.Style := psSolid;
end;

{ ProgressView() .mini: eight spokes, the lit one rotating. }
procedure TScanStatusBar.DrawSpinner(CX, CY: Integer);
var
  I, Lit: Integer;
  A: Double;
  Bg, Ink: TColor;
begin
  Bg := ColorToRGB(Color);
  Lit := ((GetTickCount64 - FAnimStart) div 100) mod 8;
  Canvas.Pen.Width := 2;
  for I := 0 to 7 do
  begin
    A := I * Pi / 4;
    Ink := SecondaryTextColor(Bg);
    if I <> Lit then
      Ink := RGBToColor((Red(Ink) + 2 * Red(Bg)) div 3, (Green(Ink) + 2 * Green(Bg)) div 3,
        (Blue(Ink) + 2 * Blue(Bg)) div 3);
    Canvas.Pen.Color := Ink;
    Canvas.Line(CX + Round(Cos(A) * 2), CY + Round(Sin(A) * 2),
      CX + Round(Cos(A) * (SpinnerSize div 2)), CY + Round(Sin(A) * (SpinnerSize div 2)));
  end;
  Canvas.Pen.Width := 1;
end;

procedure TScanStatusBar.Paint;
var
  Bg, Secondary, Tertiary: TColor;
  RowTop, TextH, X, Right, LeftEnd, W, TextY: Integer;
  ItemsText, BytesText, CapText, LeftText, Rate: string;
  ItemsW, BytesW, CapW: Integer;
  Frac: Double;
  R, LeftR, CapR, TotalR: TRect;
begin
  LeftR := Rect(0, 0, 0, 0);
  CapR := Rect(0, 0, 0, 0);
  Bg := ColorToRGB(Color);
  Secondary := SecondaryTextColor(Bg);
  Tertiary := RGBToColor((Red(Secondary) + Red(Bg)) div 2,
    (Green(Secondary) + Green(Bg)) div 2, (Blue(Secondary) + Blue(Bg)) div 2);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Bg;
  Canvas.FillRect(ClientRect);

  { Divider. }
  Canvas.Pen.Color := ColorToRGB(clBtnShadow);
  Canvas.Line(0, 0, ClientWidth, 0);

  RowTop := 1;
  if FScanning then
  begin
    DrawLinearBar(Rect(PadH, RowTop + ProgressTop, ClientWidth - PadH,
      RowTop + ProgressTop + ProgressHeight), FProgress);
    Inc(RowTop, ProgressTop + ProgressHeight);
  end;

  Canvas.Brush.Style := bsClear;
  ApplyTextStyle(Canvas.Font, tsFootnote); { ScanStatusBar.swift:72-74 }
  Canvas.Font.Style := [];
  TextH := FootnoteLine;
  TextY := RowTop + PadV;

  { Right side, laid out from the right edge. }
  Right := ClientWidth - PadH;
  if FItemCount = 1 then
    ItemsText := '· 1 item'
  else
    ItemsText := '· ' + IntToStr(FItemCount) + ' items';
  ItemsW := Canvas.TextWidth(ItemsText);
  Canvas.Font.Color := Secondary;
  Canvas.TextOut(Right - ItemsW, TextY, ItemsText);
  TotalR := Rect(Right - ItemsW, TextY, Right, TextY + TextH);
  Dec(Right, ItemsW + Spacing);

  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := ColorToRGB(clWindowText);
  BytesText := FormatFileSize(FTotalBytes);
  BytesW := TabularWidth(BytesText);
  DrawTabular(Right - BytesW, TextY, BytesText);
  TotalR.Left := Right - BytesW;
  Dec(Right, BytesW);
  Canvas.Font.Style := [];

  if FHasCapacity then
  begin
    Dec(Right, MinSpacer);
    CapText := FormatFileSize(FCapAvailable) + ' available of ' + FormatFileSize(FCapTotal);
    CapW := TabularWidth(CapText);
    Canvas.Font.Color := Secondary;
    DrawTabular(Right - CapW, TextY, CapText);
    CapR := Rect(Right - CapW, TextY, Right, TextY + TextH);
    Dec(Right, CapW + CapacityGap);
    if FCapTotal > 0 then
      Frac := (FCapTotal - FCapAvailable) / FCapTotal
    else
      Frac := 0;
    R := Rect(Right - CapacityBarWidth, TextY + (TextH - ProgressHeight) div 2,
      Right, TextY + (TextH - ProgressHeight) div 2 + ProgressHeight);
    DrawLinearBar(R, Frac);
    Canvas.Brush.Style := bsClear;
    Dec(Right, CapacityBarWidth);
    CapR.Left := Right;
  end;
  LeftEnd := Right - MinSpacer;

  { Left side. }
  X := PadH;
  Canvas.Font.Color := Secondary;
  if FScanning then
  begin
    DrawSpinner(X + SpinnerSize div 2, TextY + TextH div 2);
    Canvas.Brush.Style := bsClear;
    Inc(X, SpinnerSize + Spacing);
    LeftText := ScanStatusText;
    Rate := RateText;
  end
  else if FDuration > 0 then
  begin
    LeftText := FormatScanDuration(FDuration);
    Rate := '';
  end
  else
  begin
    LeftText := '';
    Rate := '';
  end;
  if LeftText <> '' then
  begin
    W := LeftEnd - X;
    if Rate <> '' then
      Dec(W, Spacing + Canvas.TextWidth(Rate));
    if W > 0 then
    begin
      { Full row height: a one-line rect clips descenders (and commas). }
      R := Rect(X, TextY, X + W, ClientHeight);
      { lineLimit(1): truncate the tail. }
      DrawText(Canvas.Handle, PChar(LeftText), Length(LeftText), R,
        DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);
      LeftR := Rect(X, TextY, X + W, TextY + TextH);
      Inc(X, Min(W, Canvas.TextWidth(LeftText)) + Spacing);
      if (Rate <> '') and (X + Canvas.TextWidth(Rate) <= LeftEnd) then
      begin
        Canvas.Font.Color := Tertiary;
        Canvas.TextOut(X, TextY, Rate);
      end;
    end;
  end;
  UpdateAccessibility(LeftText, LeftR, CapR, BytesText + ' ' + ItemsText, TotalR);
end;

{ SwiftUI exposes the bar's texts; the capacity readout is one element,
  "Disk space" with "<used> used, <available> available of <total>"
  (ScanStatusBar.swift:96-98). }
procedure TScanStatusBar.UpdateAccessibility(const LeftText: string; const LeftR: TRect;
  const CapR: TRect; const TotalText: string; const TotalR: TRect);
var
  Items: array of TChartAccessibleItem;
  Key, CapValue: string;
  N: Integer;
begin
  CapValue := '';
  if FHasCapacity then
    CapValue := FormatFileSize(FCapTotal - FCapAvailable) + ' used, ' +
      FormatFileSize(FCapAvailable) + ' available of ' + FormatFileSize(FCapTotal);
  Key := LeftText + #1 + CapValue + #1 + TotalText;
  if Key = FAccessibleKey then
    Exit;
  FAccessibleKey := Key;
  SetLength(Items, 3);
  N := 0;
  if LeftText <> '' then
  begin
    Items[N].ItemLabel := LeftText;
    Items[N].Value := '';
    Items[N].IsButton := False;
    Items[N].Bounds := LeftR;
    Inc(N);
  end;
  if CapValue <> '' then
  begin
    Items[N].ItemLabel := 'Disk space';
    Items[N].Value := CapValue;
    Items[N].IsButton := False;
    Items[N].Bounds := CapR;
    Inc(N);
  end;
  Items[N].ItemLabel := TotalText;
  Items[N].Value := '';
  Items[N].IsButton := False;
  Items[N].Bounds := TotalR;
  Inc(N);
  SetLength(Items, N);
  SetChartAccessibility(Self, '', Items, nil);
end;

initialization
  NumberSeparators(DecimalSep, GroupSep);
end.
