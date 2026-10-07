{ PlatformListTransition — animate a list box's rows across a refresh.

  ScanResultsView .animation(.snappy(duration: 0.18), value: displayVersion):
  rows that stay slide from their old place to the new one, rows that go
  fade out where they were, rows that arrive fade in. The native table
  forgets departed rows at once, so the list is snapshotted before and
  after the refresh, and for the duration a plain NSView above it draws
  the transition from the two snapshots. That view never takes input
  (hitTest: answers nil): clicks and scrolling reach the list underneath.
  Rows are matched by key (the row's path); places are in the list's
  client coordinates. }

unit PlatformListTransition;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

uses
  Classes, SysUtils, Controls, Graphics;

type
  TRowPlace = record
    Key: string;
    Top: Integer;
    Height: Integer;
  end;
  TRowPlaces = array of TRowPlace;

{ Snapshots List as it is now, with its visible rows' places. }
procedure CaptureListBefore(List: TWinControl; const Places: TRowPlaces);
{ After the refresh: snapshots the new list and, when visible rows moved
  or went away, animates over DurationMs (eased like .snappy). False when
  there is nothing to animate (or no snapshot was taken). }
function AnimateListAfter(List: TWinControl; const Places: TRowPlaces;
  DurationMs: Integer; Background: TColor): Boolean;
{ Drops a pending snapshot or a running transition. }
procedure CancelListTransition;

implementation

{$IFDEF DARWIN}
uses
  CocoaAll, MacOSAll, Math, Motion, PlatformMotion;

type
  TPiece = record
    FromTop, ToTop, Height: Integer;
    { 0: stays (new image, slides), 1: goes (old image, fades out),
      2: arrives (new image, fades in). }
    Kind: Integer;
  end;

  TTransition = class
    OldImage, NewImage: CGImageRef;
    Scale: Double;
    Width: Double;
    Pieces: array of TPiece;
    Anim: TAnimatedValue;
    Background: TColor;
    View: NSView;
    Clock: TFrameClock;
    procedure Frame(Sender: TObject);
    { Stops the clock, removes the view and drops the images; the object
      itself is freed with the next transition (not inside its clock's
      callback). }
    procedure Finish;
    destructor Destroy; override;
  end;

  TODTransitionView = objcclass(NSView)
  private
    FTransition: TTransition;
  public
    function isFlipped: ObjCBOOL; override;
    function hitTest(aPoint: NSPoint): NSView; override;
    procedure drawRect(dirtyRect: NSRect); override;
  end;

var
  Pending: TRowPlaces;
  PendingImage: CGImageRef = nil;
  PendingScale: Double = 2;
  Running: TTransition = nil;

function ListView(List: TWinControl): NSView;
begin
  Result := nil;
  if (List <> nil) and List.HandleAllocated then
    Result := NSView(Pointer(List.Handle));
end;

{ What the list shows now, as a CGImage (retained), and its scale. }
function Snapshot(View: NSView; out Scale: Double): CGImageRef;
var
  Rep: NSBitmapImageRep;
begin
  Result := nil;
  Scale := 2;
  Rep := View.bitmapImageRepForCachingDisplayInRect(View.bounds);
  if Rep = nil then
    Exit;
  View.cacheDisplayInRect_toBitmapImageRep(View.bounds, Rep);
  if View.bounds.size.width > 0 then
    Scale := Rep.pixelsWide / View.bounds.size.width;
  Result := Rep.CGImage;
  if Result <> nil then
    CGImageRetain(Result);
end;

procedure CaptureListBefore(List: TWinControl; const Places: TRowPlaces);
var
  V: NSView;
begin
  CancelListTransition;
  V := ListView(List);
  if V = nil then
    Exit;
  PendingImage := Snapshot(V, PendingScale);
  Pending := Copy(Places);
end;

procedure CancelListTransition;
begin
  if PendingImage <> nil then
    CGImageRelease(PendingImage);
  PendingImage := nil;
  Pending := nil;
  FreeAndNil(Running);
end;

function FindKey(const Places: TRowPlaces; const Key: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Places) do
    if Places[I].Key = Key then
      Exit(I);
  Result := -1;
end;

function AnimateListAfter(List: TWinControl; const Places: TRowPlaces;
  DurationMs: Integer; Background: TColor): Boolean;
var
  V, Host: NSView;
  T: TTransition;
  Changed: Boolean;
  I, J, N: Integer;
  OV: TODTransitionView;
  NewScale: Double;
  NewImage: CGImageRef;
  Moved: Integer;
begin
  Result := False;
  V := ListView(List);
  if (V = nil) or (PendingImage = nil) or (V.superview = nil) then
  begin
    CancelListTransition;
    Exit;
  end;
  { Something to show: a visible row went away or moved. }
  Changed := False;
  for I := 0 to High(Pending) do
  begin
    J := FindKey(Places, Pending[I].Key);
    if (J < 0) or (Places[J].Top <> Pending[I].Top) then
      Changed := True;
  end;
  if not Changed then
  begin
    CancelListTransition;
    Exit;
  end;
  NewImage := Snapshot(V, NewScale);
  if NewImage = nil then
  begin
    CancelListTransition;
    Exit;
  end;
  T := TTransition.Create;
  T.OldImage := PendingImage;
  PendingImage := nil;
  T.NewImage := NewImage;
  T.Scale := NewScale;
  T.Width := V.bounds.size.width;
  T.Background := Background;
  N := 0;
  SetLength(T.Pieces, Length(Pending) + Length(Places));
  for I := 0 to High(Places) do
  begin
    J := FindKey(Pending, Places[I].Key);
    T.Pieces[N].ToTop := Places[I].Top;
    T.Pieces[N].Height := Places[I].Height;
    if J >= 0 then
    begin
      T.Pieces[N].FromTop := Pending[J].Top;
      T.Pieces[N].Kind := 0;
    end
    else
    begin
      T.Pieces[N].FromTop := Places[I].Top;
      T.Pieces[N].Kind := 2;
    end;
    Inc(N);
  end;
  for I := 0 to High(Pending) do
    if FindKey(Places, Pending[I].Key) < 0 then
    begin
      T.Pieces[N].FromTop := Pending[I].Top;
      T.Pieces[N].ToTop := Pending[I].Top;
      T.Pieces[N].Height := Pending[I].Height;
      T.Pieces[N].Kind := 1;
      Inc(N);
    end;
  SetLength(T.Pieces, N);
  Pending := nil;
  if GetEnvironmentVariable('OPENDISK_DEBUG_MOTION') = '1' then
  begin
    J := 0;
    Moved := 0;
    for I := 0 to N - 1 do
      if T.Pieces[I].Kind = 0 then
      begin
        Inc(J);
        if T.Pieces[I].FromTop <> T.Pieces[I].ToTop then
          Inc(Moved);
      end;
    WriteLn(Format('list transition: %d stay (%d move), %d go, %d arrive',
      [J, Moved, N - Length(Places), Length(Places) - J]));
    Flush(Output);
  end;
  T.Anim := AnimatedAt(0);
  Retarget(T.Anim, 1, GetTickCount64, DurationMs, eaSnappy);

  { A sibling above the list, same frame, drawing the transition. }
  Host := V.superview;
  OV := TODTransitionView.alloc.initWithFrame(V.frame);
  OV.FTransition := T;
  Host.addSubview_positioned_relativeTo(OV, NSWindowAbove, V);
  T.View := OV;
  OV.release;
  Running := T;
  T.Clock := TFrameClock.Create(List, @T.Frame);
  T.Clock.Start;
  Result := True;
end;

procedure TTransition.Frame(Sender: TObject);
begin
  if AtRest(Anim, GetTickCount64) then
  begin
    { The list underneath is already in its new state. }
    Finish;
    Exit;
  end;
  if GetEnvironmentVariable('OPENDISK_DEBUG_MOTION') = '1' then
  begin
    WriteLn(Format('list frame %.3f', [ValueAt(Anim, GetTickCount64)]));
    Flush(Output);
  end;
  if View <> nil then
    View.setNeedsDisplay_(True);
end;

procedure TTransition.Finish;
begin
  if Clock <> nil then
    Clock.Stop;
  if View <> nil then
  begin
    TODTransitionView(View).FTransition := nil;
    View.removeFromSuperview;
    View := nil;
  end;
  if OldImage <> nil then
    CGImageRelease(OldImage);
  OldImage := nil;
  if NewImage <> nil then
    CGImageRelease(NewImage);
  NewImage := nil;
end;

destructor TTransition.Destroy;
begin
  Finish;
  Clock.Free;
  inherited Destroy;
end;

function TODTransitionView.isFlipped: ObjCBOOL;
begin
  Result := True;
end;

function TODTransitionView.hitTest(aPoint: NSPoint): NSView;
begin
  { Input goes to the list underneath. }
  Result := nil;
end;

{ Draws the H-point slice at SrcTop of Image at DstTop, with Alpha. The
  view is flipped, so each image is drawn upside down into a flipped
  rectangle. }
procedure DrawSlice(Ctx: CGContextRef; Image: CGImageRef; Scale, Width: Double;
  SrcTop, DstTop, H: Integer; Alpha: Double);
var
  Slice: CGImageRef;
begin
  if (Image = nil) or (H <= 0) or (Alpha <= 0.001) or (SrcTop < 0) then
    Exit;
  Slice := CGImageCreateWithImageInRect(Image,
    CGRectMake(0, SrcTop * Scale, Width * Scale, H * Scale));
  if Slice = nil then
    Exit;
  CGContextSaveGState(Ctx);
  CGContextSetAlpha(Ctx, Min(1, Alpha));
  CGContextTranslateCTM(Ctx, 0, DstTop + H);
  CGContextScaleCTM(Ctx, 1, -1);
  CGContextDrawImage(Ctx, CGRectMake(0, 0, Width, H), Slice);
  CGContextRestoreGState(Ctx);
  CGImageRelease(Slice);
end;

procedure TODTransitionView.drawRect(dirtyRect: NSRect);
var
  Ctx: CGContextRef;
  T: TTransition;
  P: Double;
  I: Integer;
  RGB: TColor;
begin
  T := FTransition;
  if T = nil then
    Exit;
  Ctx := CGContextRef(NSGraphicsContext.currentContext.graphicsPort);
  RGB := ColorToRGB(T.Background);
  CGContextSetRGBFillColor(Ctx, Red(RGB) / 255, Green(RGB) / 255, Blue(RGB) / 255, 1);
  CGContextFillRect(Ctx, CGRectMake(0, 0, bounds.size.width, bounds.size.height));
  P := ValueAt(T.Anim, GetTickCount64);
  for I := 0 to High(T.Pieces) do
    with T.Pieces[I] do
      case Kind of
        0: DrawSlice(Ctx, T.NewImage, T.Scale, T.Width, ToTop,
             Round(FromTop + (ToTop - FromTop) * P), Height, 1);
        1: DrawSlice(Ctx, T.OldImage, T.Scale, T.Width, FromTop, FromTop, Height, 1 - P);
        2: DrawSlice(Ctx, T.NewImage, T.Scale, T.Width, ToTop, ToTop, Height, P);
      end;
end;

{$ELSE}

procedure CaptureListBefore(List: TWinControl; const Places: TRowPlaces);
begin
end;

function AnimateListAfter(List: TWinControl; const Places: TRowPlaces;
  DurationMs: Integer; Background: TColor): Boolean;
begin
  Result := False;
end;

procedure CancelListTransition;
begin
end;

{$ENDIF}

end.
