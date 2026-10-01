{ OpenDisk Formatters — human-readable byte sizes. }

unit Formatters;

{$mode objfpc}{$H+}

interface

function FormatFileSize(Bytes: Int64): string;

implementation

uses
  SysUtils;

function FormatFileSize(Bytes: Int64): string;
const
  KB = 1024;
  MB = KB * 1024;
  GB = MB * 1024;
  TB = GB * 1024;
begin
  if Bytes < 0 then
    Bytes := 0;
  if Bytes < KB then
    Result := IntToStr(Bytes) + ' bytes'
  else if Bytes < MB then
    Result := Format('%.1f KB', [Bytes / KB])
  else if Bytes < GB then
    Result := Format('%.1f MB', [Bytes / MB])
  else if Bytes < TB then
    Result := Format('%.2f GB', [Bytes / GB])
  else
    Result := Format('%.2f TB', [Bytes / TB]);
end;

end.
