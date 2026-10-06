{ EmptyStateView — SwiftUI ContentUnavailableView for the LCL.

  A centred block: SF Symbol glyph, bold title, secondary description
  wrapped to a readable width, then optional buttons side by side (the
  first is the default). Used for "No Disks Found", "Full Disk Access
  Required", "Couldn't Read This Location" and "Nothing to Show".
  SetBusy shows ProgressView("…") instead: a spinner over a label. }

unit EmptyStateView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, StdCtrls, ExtCtrls, Types;

type
  TEmptyStateView = class(TCustomControl)
  private
    FSymbol, FTitle, FDescription: string;
    FGlyph: TBitmap;
    FGlyphColor: TColor;
    FButtons: array of TButton;
    FBlockTop, FTitleH, FDescH: Integer;
    FBusy: Boolean;
    FSpin: TTimer;
    FSpinStart: QWord;
    procedure SpinTick(Sender: TObject);
    procedure PaintBusy;
    procedure Measure;
    procedure LayoutButtons;
    function DescriptionRect: TRect;
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Replaces the content; Captions[i] runs Handlers[i]. }
    procedure SetState(const Symbol, Title, Description: string;
      const Captions: array of string; const Handlers: array of TNotifyEvent);
    { ProgressView(Title): an indeterminate spinner and its label. }
    procedure SetBusy(const Title: string);
    property Busy: Boolean read FBusy;
  end;

implementation

uses
  Math, LCLType, LCLIntf, GuiColors, PlatformImages;

const
  GlyphSize = 44;
  GapGlyphTitle = 12;
  GapTitleDesc = 6;
  GapDescButtons = 16;
  { Visible spacing between bezels, as native button rows show. }
  ButtonGap = 12;
  ButtonHeight = 28;
  DescWidth = 360;
  TitleSize = 17;
  DescSize = 13;

constructor TEmptyStateView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FSpin := TTimer.Create(Self);
  FSpin.Enabled := False;
  { 12 steps a second, like the system spinner. }
  FSpin.Interval := 83;
  FSpin.OnTimer := @SpinTick;
end;

function Blend(A, B: TColor; T: Double): TColor;
var
  CA, CB: LongInt;
begin
  CA := ColorToRGB(A);
  CB := ColorToRGB(B);
  Result := RGBToColor(
    Round(Red(CA) + (Red(CB) - Red(CA)) * T),
    Round(Green(CA) + (Green(CB) - Green(CA)) * T),
    Round(Blue(CA) + (Blue(CB) - Blue(CA)) * T));
end;

procedure TEmptyStateView.SetBusy(const Title: string);
var
  I: Integer;
begin
  for I := 0 to High(FButtons) do
    FButtons[I].Free;
  FButtons := nil;
  FSymbol := '';
  FDescription := '';
  FTitle := Title;
  FBusy := True;
  FSpinStart := GetTickCount64;
  FSpin.Enabled := True;
  Invalidate;
end;

procedure TEmptyStateView.SpinTick(Sender: TObject);
begin
  { No timer while hidden or idle. }
  if not FBusy or not IsVisible then
  begin
    FSpin.Enabled := FBusy and Visible;
    if not FBusy then
      Exit;
  end;
  if IsVisible then
    Invalidate;
end;

procedure TEmptyStateView.PaintBusy;
const
  Spokes = 12;
  Radius = 16;
var
  Secondary, Bg, Ink: TColor;
  CX, CY, I, Lit, Age: Integer;
  A: Double;
begin
  Bg := ColorToRGB(Color);
  Secondary := SecondaryTextColor(Bg);
  Ink := ColorToRGB(clWindowText);
  CX := ClientWidth div 2;
  CY := ClientHeight div 2 - 12;
  Lit := ((GetTickCount64 - FSpinStart) div 83) mod Spokes;
  Canvas.Pen.Width := 3;
  for I := 0 to Spokes - 1 do
  begin
    A := I * 2 * Pi / Spokes - Pi / 2;
    { The lit spoke is darkest; the trail fades behind it. }
    Age := (Lit - I + Spokes) mod Spokes;
    Canvas.Pen.Color := Blend(Ink, Bg, 0.25 + 0.6 * Age / (Spokes - 1));
    Canvas.Line(CX + Round(Cos(A) * Radius * 0.5), CY + Round(Sin(A) * Radius * 0.5),
      CX + Round(Cos(A) * Radius), CY + Round(Sin(A) * Radius));
  end;
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Size := DescSize;
  Canvas.Font.Style := [];
  Canvas.Font.Color := Secondary;
  Canvas.TextOut((ClientWidth - Canvas.TextWidth(FTitle)) div 2, CY + Radius + 10, FTitle);
end;

destructor TEmptyStateView.Destroy;
begin
  FGlyph.Free;
  inherited Destroy;
end;

procedure TEmptyStateView.SetState(const Symbol, Title, Description: string;
  const Captions: array of string; const Handlers: array of TNotifyEvent);
var
  I: Integer;
begin
  FBusy := False;
  FSpin.Enabled := False;
  for I := 0 to High(FButtons) do
    FButtons[I].Free;
  SetLength(FButtons, Length(Captions));
  for I := 0 to High(Captions) do
  begin
    FButtons[I] := TButton.Create(Self);
    FButtons[I].Parent := Self;
    FButtons[I].Caption := Captions[I];
    FButtons[I].Default := I = 0;
    if I <= High(Handlers) then
      FButtons[I].OnClick := Handlers[I];
  end;
  if Symbol <> FSymbol then
    FreeAndNil(FGlyph);
  FSymbol := Symbol;
  FTitle := Title;
  FDescription := Description;
  Measure;
  LayoutButtons;
  Invalidate;
end;

function TEmptyStateView.DescriptionRect: TRect;
var
  W: Integer;
begin
  W := Min(DescWidth, Max(120, ClientWidth - 32));
  Result := Rect((ClientWidth - W) div 2, 0, (ClientWidth + W) div 2, 0);
end;

procedure TEmptyStateView.Measure;
var
  R: TRect;
  Total: Integer;
begin
  if not HandleAllocated then
    Exit;
  Canvas.Font.Size := TitleSize;
  Canvas.Font.Style := [fsBold];
  FTitleH := Canvas.TextHeight('Ag');
  Canvas.Font.Size := DescSize;
  Canvas.Font.Style := [];
  R := DescriptionRect;
  R.Bottom := R.Top + 1000;
  DrawText(Canvas.Handle, PChar(FDescription), Length(FDescription), R,
    DT_CALCRECT or DT_WORDBREAK or DT_CENTER or DT_NOPREFIX);
  FDescH := R.Bottom - R.Top;
  Total := GlyphSize + GapGlyphTitle + FTitleH + GapTitleDesc + FDescH;
  if Length(FButtons) > 0 then
    Inc(Total, GapDescButtons + ButtonHeight);
  FBlockTop := Max(16, (ClientHeight - Total) div 2);
end;

procedure TEmptyStateView.LayoutButtons;
var
  I, W, X, Y: Integer;
  Widths: array of Integer;
begin
  if Length(FButtons) = 0 then
    Exit;
  SetLength(Widths, Length(FButtons));
  W := 0;
  Canvas.Font.Size := DescSize;
  for I := 0 to High(FButtons) do
  begin
    Widths[I] := Max(96, Canvas.TextWidth(FButtons[I].Caption) + 32);
    Inc(W, Widths[I]);
  end;
  Inc(W, ButtonGap * High(FButtons));
  X := (ClientWidth - W) div 2;
  Y := FBlockTop + GlyphSize + GapGlyphTitle + FTitleH + GapTitleDesc + FDescH +
    GapDescButtons;
  for I := 0 to High(FButtons) do
  begin
    FButtons[I].SetBounds(X, Y, Widths[I], ButtonHeight);
    Inc(X, Widths[I] + ButtonGap);
  end;
end;

procedure TEmptyStateView.Resize;
begin
  inherited Resize;
  Measure;
  LayoutButtons;
  Invalidate;
end;

procedure TEmptyStateView.Paint;
var
  Bg, Secondary: TColor;
  R: TRect;
  Y: Integer;
begin
  Bg := ColorToRGB(Color);
  Secondary := SecondaryTextColor(Bg);
  Canvas.Brush.Color := Bg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  if FBusy then
  begin
    PaintBusy;
    Exit;
  end;
  Measure;
  Y := FBlockTop;

  if (FGlyph = nil) or (FGlyphColor <> Secondary) then
  begin
    FreeAndNil(FGlyph);
    FGlyphColor := Secondary;
    if FSymbol <> '' then
      FGlyph := SystemSymbolBitmap(FSymbol, 2 * GlyphSize, Secondary);
  end;
  if FGlyph <> nil then
    Canvas.StretchDraw(Rect((ClientWidth - GlyphSize) div 2, Y,
      (ClientWidth + GlyphSize) div 2, Y + GlyphSize), FGlyph);
  Inc(Y, GlyphSize + GapGlyphTitle);

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Size := TitleSize;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := ColorToRGB(clWindowText);
  Canvas.TextOut((ClientWidth - Canvas.TextWidth(FTitle)) div 2, Y, FTitle);
  Inc(Y, FTitleH + GapTitleDesc);

  Canvas.Font.Size := DescSize;
  Canvas.Font.Style := [];
  Canvas.Font.Color := Secondary;
  R := DescriptionRect;
  R.Top := Y;
  R.Bottom := Y + FDescH;
  DrawText(Canvas.Handle, PChar(FDescription), Length(FDescription), R,
    DT_WORDBREAK or DT_CENTER or DT_NOPREFIX);
end;

end.
