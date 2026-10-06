program quicklook_demo;

{ Quick Look over a form: the button previews a text file and a PNG (the
  arrow keys switch between them). OPENDISK_DEMO_QUICKLOOK=1 opens the
  panel shortly after launch, for screenshots. Files go to the temp dir. }

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, StdCtrls, Controls, ExtCtrls, Classes, SysUtils, Graphics,
  PlatformQuickLook;

type
  TDemoForm = class(TForm)
  public
    Paths: array of string;
    procedure PreviewClick(Sender: TObject);
    procedure AutoTick(Sender: TObject);
  end;

procedure TDemoForm.PreviewClick(Sender: TObject);
begin
  ShowQuickLook(Self, Paths, 0);
end;

procedure TDemoForm.AutoTick(Sender: TObject);
begin
  (Sender as TTimer).Enabled := False;
  PreviewClick(nil);
end;

var
  Form: TDemoForm;
  Button: TButton;
  Scratch: string;
  Png: TPortableNetworkGraphic;
  X, Y: Integer;
begin
  Application.Initialize;
  Scratch := GetTempDir(False) + 'opendisk-quicklook-demo';
  ForceDirectories(Scratch);
  Form := TDemoForm.CreateNew(nil);
  SetLength(Form.Paths, 2);
  Form.Paths[0] := Scratch + '/sample.txt';
  Form.Paths[1] := Scratch + '/sample.png';
  with TStringList.Create do
  try
    Text := 'OpenDisk Quick Look demo' + LineEnding + LineEnding + 'Preview panel content.';
    SaveToFile(Form.Paths[0]);
  finally
    Free;
  end;
  Png := TPortableNetworkGraphic.Create;
  try
    Png.SetSize(64, 64);
    for Y := 0 to 63 do
      for X := 0 to 63 do
        Png.Canvas.Pixels[X, Y] := RGBToColor(X * 4, Y * 4, 160);
    Png.SaveToFile(Form.Paths[1]);
  finally
    Png.Free;
  end;
  Form.Caption := 'OpenDisk Quick Look demo';
  Form.Width := 420;
  Form.Height := 150;
  Button := TButton.Create(Form);
  Button.Parent := Form;
  Button.Caption := 'Preview sample files';
  Button.SetBounds(120, 55, 180, 32);
  Button.OnClick := @Form.PreviewClick;
  Form.Show;
  if GetEnvironmentVariable('OPENDISK_DEMO_QUICKLOOK') = '1' then
    with TTimer.Create(Form) do
    begin
      Interval := 600;
      OnTimer := @Form.AutoTick;
      Enabled := True;
    end;
  Application.Run;
end.
