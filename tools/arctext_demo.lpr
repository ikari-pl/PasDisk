program arctext_demo;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Controls, Graphics, Math, PlatformChartCanvas;

type
  TArcView = class(TCustomControl)
  protected
    procedure Paint; override;
  end;

procedure TArcView.Paint;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  Canvas.Pen.Color := clBtnShadow;
  Canvas.Pen.Style := psSolid;
  Canvas.Brush.Style := bsClear;
  Canvas.Ellipse(80, 40, 300, 260);
  Canvas.Ellipse(380, 40, 600, 260);
  Canvas.Ellipse(680, 40, 900, 260);
  Canvas.Pen.Width := 2;
  Canvas.MoveTo(190, 150 - 90);
  Canvas.LineTo(190, 150 - 78);
  Canvas.MoveTo(490, 150 + 90);
  Canvas.LineTo(490, 150 + 78);
  Canvas.MoveTo(790 + 90, 150);
  Canvas.LineTo(790 + 78, 150);
  DrawTextOnArc(Canvas, 'Upper arc label', 190, 150, 90, -Pi / 2, clWindowText, 12, False);
  DrawTextOnArc(Canvas, 'Lower arc stays upright', 490, 150, 90, Pi / 2, clWindowText, 12, True);
  DrawTextOnArc(Canvas, 'East label', 790, 150, 90, 0, clWindowText, 12, False);
end;

var
  Form: TForm;
  View: TArcView;
begin
  Application.Initialize;
  Form := TForm.Create(nil);
  Form.Caption := 'OpenDisk arc text demo';
  Form.Width := 980;
  Form.Height := 330;
  View := TArcView.Create(Form);
  View.Parent := Form;
  View.Align := alClient;
  Form.Show;
  Application.Run;
end.
