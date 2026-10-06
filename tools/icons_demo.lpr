program icons_demo;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Controls, Graphics, Classes, SysUtils, Types,
  PlatformImages;

type
  TIconCanvas = class(TCustomControl)
  protected
    procedure Paint; override;
  end;

procedure TIconCanvas.Paint;
var
  Paths: TStringList;
  I, X: Integer;
  Path: string;
  IsDir: Boolean;
begin
  Canvas.Brush.Color := ColorToRGB(clWindow);
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  Paths := TStringList.Create;
  try
    ExtractStrings([':'], [], PChar(GetEnvironmentVariable('OPENDISK_DEMO_PATHS')), Paths);
    X := 16;
    for I := 0 to Paths.Count - 1 do
    begin
      Path := Paths[I];
      IsDir := DirectoryExists(Path);
      DrawFileIcon(Canvas, Rect(X, 16, X + 44, 60), Path, IsDir);
      Canvas.Brush.Style := bsClear;
      Canvas.Font.Color := ColorToRGB(clWindowText);
      Canvas.Font.Size := 9;
      Canvas.TextOut(X, 66, ExtractFileName(Path));
      Inc(X, 140);
    end;
  finally
    Paths.Free;
  end;
end;

var
  Form: TForm;
  View: TIconCanvas;
begin
  Application.Initialize;
  Form := TForm.Create(nil);
  Form.Caption := 'OpenDisk file icon demo';
  Form.Width := 720;
  Form.Height := 120;
  View := TIconCanvas.Create(Form);
  View.Parent := Form;
  View.Align := alClient;
  Form.Show;
  Application.Run;
end.
