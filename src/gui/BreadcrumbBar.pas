{ BreadcrumbBar — clickable path from the scan root to the current folder.

  Port of OpenDisk Views/Components/BreadcrumbBar.swift: ancestors are
  secondary-coloured links that turn primary over a rounded hover wash, the
  current folder is semibold and not a link, chevrons separate segments.
  Swift scrolls an over-long trail horizontally; here the middle collapses
  to an ellipsis, keeping the root and the current folder, and if that is
  still too wide the widest names are truncated in the middle. The full
  path is the control's hint. }

unit BreadcrumbBar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, Types;

type
  TBreadcrumbNavigate = procedure(const Path: string) of object;

  TCrumbSegment = record
    Name: string;
    FullName: string;
    Path: string;
    Bounds: TRect;
    IsLast: Boolean;
    IsEllipsis: Boolean;
  end;

  TBreadcrumbBar = class(TCustomControl)
  private
    FRootPath, FRootName, FCurrentPath: string;
    FSegments: array of TCrumbSegment;
    FHover: Integer;
    FOnNavigate: TBreadcrumbNavigate;
    procedure BuildSegments;
    procedure Layout;
    function SegmentAt(X, Y: Integer): Integer;
    procedure SetHover(Index: Integer);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { Shows RootName for RootPath and one segment per folder below it down
      to CurrentPath. }
    procedure SetPath(const RootPath, RootName, CurrentPath: string);
    property OnNavigate: TBreadcrumbNavigate read FOnNavigate write FOnNavigate;
  end;

implementation

uses
  GuiColors, TextTrim;

const
  PadX = 6;       { BreadcrumbLink .padding(.horizontal, 6) }
  Spacing = 3;    { HStack(spacing: 3) }
  ChevronW = 8;
  Inset = 14;     { .padding(.horizontal, 14) }
  FontPt = 12;

constructor TBreadcrumbBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := 28;
  FHover := -1;
  DoubleBuffered := True;
end;

procedure TBreadcrumbBar.SetPath(const RootPath, RootName, CurrentPath: string);
begin
  FRootPath := ExcludeTrailingPathDelimiter(RootPath);
  if FRootPath = '' then
    FRootPath := RootPath;
  FRootName := RootName;
  FCurrentPath := CurrentPath;
  FHover := -1;
  Hint := CurrentPath;
  ShowHint := True;
  BuildSegments;
  Layout;
  Invalidate;
end;

procedure TBreadcrumbBar.BuildSegments;
var
  Rel, Acc, Part: string;
  Parts: TStringList;
  I, N: Integer;
begin
  SetLength(FSegments, 1);
  FSegments[0].Name := FRootName;
  FSegments[0].FullName := FRootName;
  FSegments[0].Path := FRootPath;
  FSegments[0].IsEllipsis := False;
  FSegments[0].IsLast := (FCurrentPath = '') or
    (ExcludeTrailingPathDelimiter(FCurrentPath) = FRootPath);
  if FSegments[0].IsLast then
    Exit;
  Rel := Copy(FCurrentPath, Length(IncludeTrailingPathDelimiter(FRootPath)) + 1, MaxInt);
  if Copy(FCurrentPath, 1, Length(IncludeTrailingPathDelimiter(FRootPath))) <>
     IncludeTrailingPathDelimiter(FRootPath) then
    Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := PathDelim;
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Rel;
    Acc := FRootPath;
    for I := 0 to Parts.Count - 1 do
    begin
      Part := Parts[I];
      if Part = '' then
        Continue;
      Acc := IncludeTrailingPathDelimiter(Acc) + Part;
      N := Length(FSegments);
      SetLength(FSegments, N + 1);
      FSegments[N].Name := Part;
      FSegments[N].FullName := Part;
      FSegments[N].Path := Acc;
      FSegments[N].IsEllipsis := False;
      FSegments[N].IsLast := False;
    end;
  finally
    Parts.Free;
  end;
  FSegments[High(FSegments)].IsLast := True;
end;

procedure TBreadcrumbBar.Layout;
const
  MinKeep = 6;
var
  I, X, W, Total, Cut, Widest, WidestW, Keep: Integer;

  function TextW(const S: string; Bold: Boolean): Integer;
  begin
    Canvas.Font.Size := FontPt;
    if Bold then
      Canvas.Font.Style := [fsBold]
    else
      Canvas.Font.Style := [];
    Result := Canvas.TextWidth(S);
  end;

  function Measure: Integer;
  var
    J: Integer;
  begin
    Result := Inset * 2;
    for J := 0 to High(FSegments) do
    begin
      Inc(Result, TextW(FSegments[J].Name, FSegments[J].IsLast) + PadX * 2);
      if not FSegments[J].IsLast then
        Inc(Result, Spacing * 2 + ChevronW);
    end;
  end;

begin
  if not HandleAllocated or (Length(FSegments) = 0) then
    Exit;
  { Collapse the middle (after the root, before the current folder) into a
    single ellipsis until the trail fits. }
  Total := Measure;
  while (Total > ClientWidth) and (Length(FSegments) > 3) do
  begin
    Cut := 1;
    if FSegments[1].IsEllipsis then
      Cut := 2;
    FSegments[1].Name := #$E2#$80#$A6;
    FSegments[1].Path := '';
    FSegments[1].IsEllipsis := True;
    if Cut = 2 then
    begin
      for I := 2 to High(FSegments) - 1 do
        FSegments[I] := FSegments[I + 1];
      SetLength(FSegments, Length(FSegments) - 1);
    end;
    Total := Measure;
  end;
  { Still too wide (few, long names): truncate the widest name in the
    middle, one character at a time, down to MinKeep characters. }
  while Total > ClientWidth do
  begin
    Widest := -1;
    WidestW := 0;
    for I := 0 to High(FSegments) do
      if not FSegments[I].IsEllipsis and
         (CodePointCount(FSegments[I].Name) > MinKeep + 1) then
      begin
        W := TextW(FSegments[I].Name, FSegments[I].IsLast);
        if W > WidestW then
        begin
          WidestW := W;
          Widest := I;
        end;
      end;
    if Widest < 0 then
      Break;
    Keep := CodePointCount(FSegments[Widest].Name) - 2;
    if FSegments[Widest].Name <> FSegments[Widest].FullName then
      Dec(Keep);
    FSegments[Widest].Name := TruncateMiddle(FSegments[Widest].FullName, Keep);
    Total := Measure;
  end;
  X := Inset;
  for I := 0 to High(FSegments) do
  begin
    W := TextW(FSegments[I].Name, FSegments[I].IsLast) + PadX * 2;
    FSegments[I].Bounds := Rect(X, 2, X + W, ClientHeight - 2);
    X := X + W;
    if not FSegments[I].IsLast then
      X := X + Spacing * 2 + ChevronW;
  end;
end;

procedure TBreadcrumbBar.Resize;
begin
  inherited Resize;
  BuildSegments;
  Layout;
end;

procedure TBreadcrumbBar.Paint;
var
  I, MidY, CX: Integer;
  Bg, Ink, Secondary, Tertiary, Wash: TColor;
  S: TCrumbSegment;
begin
  Bg := ColorToRGB(Color);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Bg;
  Canvas.FillRect(ClientRect);
  if Length(FSegments) = 0 then
    Exit;
  if FSegments[0].Bounds.Right = 0 then
    Layout;
  Ink := ColorToRGB(clWindowText);
  Secondary := SecondaryTextColor(Color);
  Tertiary := RGBToColor((Red(Secondary) * 2 + Red(Bg)) div 3,
    (Green(Secondary) * 2 + Green(Bg)) div 3, (Blue(Secondary) * 2 + Blue(Bg)) div 3);
  Wash := RGBToColor((Red(Secondary) + 5 * Red(Bg)) div 6,
    (Green(Secondary) + 5 * Green(Bg)) div 6, (Blue(Secondary) + 5 * Blue(Bg)) div 6);
  MidY := ClientHeight div 2;
  Canvas.Font.Size := FontPt;
  for I := 0 to High(FSegments) do
  begin
    S := FSegments[I];
    if (I = FHover) and not S.IsLast and not S.IsEllipsis then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := Wash;
      Canvas.Pen.Style := psClear;
      Canvas.RoundRect(S.Bounds, 10, 10);
      Canvas.Pen.Style := psSolid;
    end;
    Canvas.Brush.Style := bsClear;
    if S.IsLast then
    begin
      Canvas.Font.Style := [fsBold];
      Canvas.Font.Color := Ink;
    end
    else
    begin
      Canvas.Font.Style := [];
      if (I = FHover) and not S.IsEllipsis then
        Canvas.Font.Color := Ink
      else
        Canvas.Font.Color := Secondary;
    end;
    Canvas.TextOut(S.Bounds.Left + PadX, MidY - Canvas.TextHeight(S.Name) div 2, S.Name);
    if not S.IsLast then
    begin
      CX := S.Bounds.Right + Spacing + 2;
      Canvas.Pen.Color := Tertiary;
      Canvas.Pen.Width := 1;
      Canvas.MoveTo(CX, MidY - 4);
      Canvas.LineTo(CX + 4, MidY);
      Canvas.LineTo(CX, MidY + 4);
    end;
  end;
end;

function TBreadcrumbBar.SegmentAt(X, Y: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FSegments) do
    if PtInRect(FSegments[I].Bounds, Point(X, Y)) then
      Exit(I);
  Result := -1;
end;

procedure TBreadcrumbBar.SetHover(Index: Integer);
begin
  if (Index >= 0) and (FSegments[Index].IsLast or FSegments[Index].IsEllipsis) then
    Index := -1;
  if Index = FHover then
    Exit;
  FHover := Index;
  if Index >= 0 then
    Cursor := crHandPoint
  else
    Cursor := crDefault;
  Invalidate;
end;

procedure TBreadcrumbBar.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  SetHover(SegmentAt(X, Y));
end;

procedure TBreadcrumbBar.MouseLeave;
begin
  inherited MouseLeave;
  SetHover(-1);
end;

procedure TBreadcrumbBar.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;
  I := SegmentAt(X, Y);
  if (I >= 0) and not FSegments[I].IsLast and not FSegments[I].IsEllipsis and
     Assigned(FOnNavigate) then
    FOnNavigate(FSegments[I].Path);
end;

end.
