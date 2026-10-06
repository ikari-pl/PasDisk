{ ThinSplitter — an HSplitView divider: a 1-point separator line with a
  wider grab area that resizes the control to its left. (LCL's TSplitter
  is not used: on Cocoa the pane it sizes stopped painting.) }

unit ThinSplitter;

{$mode objfpc}{$H+}

interface

uses
  Classes, Controls, Graphics;

type
  { NewWidth is proposed for the left pane; the handler may clamp it. }
  TSplitDragEvent = procedure(Sender: TObject; var NewWidth: Integer) of object;

  TThinSplitter = class(TCustomControl)
  private
    FPane: TControl;
    FDragging: Boolean;
    FGrabX: Integer;
    FOnDrag: TSplitDragEvent;
    FOnMoved: TNotifyEvent;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { The left pane this divider resizes. }
    property Pane: TControl read FPane write FPane;
    property OnDrag: TSplitDragEvent read FOnDrag write FOnDrag;
    property OnMoved: TNotifyEvent read FOnMoved write FOnMoved;
  end;

implementation

constructor TThinSplitter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 5;
  Cursor := crHSplit;
end;

procedure TThinSplitter.Paint;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := ColorToRGB(Color);
  Canvas.FillRect(ClientRect);
  { The hairline sits on the list's edge, as NSSplitView's thin divider. }
  Canvas.Pen.Color := ColorToRGB(clBtnShadow);
  Canvas.Line(0, 0, 0, ClientHeight);
end;

procedure TThinSplitter.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and (FPane <> nil) then
  begin
    FDragging := True;
    FGrabX := X;
  end;
end;

procedure TThinSplitter.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  W: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging or not (ssLeft in Shift) then
    Exit;
  W := FPane.Width + X - FGrabX;
  if Assigned(FOnDrag) then
    FOnDrag(Self, W);
  if W <> FPane.Width then
    FPane.Width := W;
end;

procedure TThinSplitter.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging and (Button = mbLeft) then
  begin
    FDragging := False;
    if Assigned(FOnMoved) then
      FOnMoved(Self);
  end;
end;

end.
