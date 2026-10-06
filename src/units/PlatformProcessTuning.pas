{ PlatformProcessTuning — process settings for heavy scanning.

  ScanEngine.swift processTuning, applied once before the first scan:
  disk I/O policy IMPORTANT (setiopolicy_np) and the open-file soft limit
  raised to min(65536, hard limit). Other systems: the same file limit
  where the RTL exposes it; no I/O policy. }

unit PlatformProcessTuning;

{$mode objfpc}{$H+}

interface

procedure TuneProcessForScanning;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;

{$IFDEF DARWIN}
const
  IOPOL_TYPE_DISK = 0;
  IOPOL_SCOPE_PROCESS = 0;
  IOPOL_IMPORTANT = 1;

function setiopolicy_np(IOType, Scope, Policy: cint): cint; cdecl;
  external 'c' name 'setiopolicy_np';
{$ENDIF}

var
  Tuned: Boolean = False;

procedure TuneProcessForScanning;
var
  Limit: TRLimit;
begin
  if Tuned then
    Exit;
  Tuned := True;
  {$IFDEF DARWIN}
  setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT);
  {$ENDIF}
  if fpGetRLimit(RLIMIT_NOFILE, @Limit) = 0 then
  begin
    if Limit.rlim_max < 65536 then
      Limit.rlim_cur := Limit.rlim_max
    else
      Limit.rlim_cur := 65536;
    fpSetRLimit(RLIMIT_NOFILE, @Limit);
  end;
end;
{$ELSE}
procedure TuneProcessForScanning;
begin
end;
{$ENDIF}

end.
