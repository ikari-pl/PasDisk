{ PlatformCacheCatalog — well-known, safely regenerable cache folders.

  macOS: Models/HiddenSpace.swift CleanableCacheCatalog, entry for entry,
  under the account's home (UserHome.swift: getpwuid). Other systems have
  no catalog in the Swift app, so none is invented here. }

unit PlatformCacheCatalog;

{$mode objfpc}{$H+}

interface

type
  TCacheLocation = record
    Name: string;
    Path: string;
  end;
  TCacheLocations = array of TCacheLocation;

function CleanableCacheLocations: TCacheLocations;

implementation

{$IFDEF DARWIN}
uses
  PlatformFS;

function CleanableCacheLocations: TCacheLocations;
const
  { Name, path; '~' stands for the account's home folder. }
  Entries: array[0..22, 0..1] of string = (
    ('Homebrew Cache', '~/Library/Caches/Homebrew'),
    ('npm Cache', '~/.npm/_cacache'),
    ('Yarn Cache', '~/Library/Caches/Yarn'),
    ('pnpm Store', '~/Library/pnpm/store'),
    ('pip Cache', '~/Library/Caches/pip'),
    ('Cargo Registry Cache', '~/.cargo/registry/cache'),
    ('Go Build Cache', '~/Library/Caches/go-build'),
    ('Go Module Cache', '~/go/pkg/mod/cache'),
    ('Gradle Cache', '~/.gradle/caches'),
    ('CocoaPods Cache', '~/Library/Caches/CocoaPods'),
    ('Composer Cache', '~/.composer/cache'),
    ('Xcode DerivedData', '~/Library/Developer/Xcode/DerivedData'),
    ('Xcode iOS DeviceSupport', '~/Library/Developer/Xcode/iOS DeviceSupport'),
    ('Xcode Archives', '~/Library/Developer/Xcode/Archives'),
    ('Playwright Browsers', '~/.cache/ms-playwright'),
    ('Puppeteer Browsers', '~/.cache/puppeteer'),
    ('Chrome Cache', '~/Library/Caches/Google/Chrome'),
    ('Safari Cache', '~/Library/Caches/com.apple.Safari'),
    ('Hugging Face Cache', '~/.cache/huggingface'),
    ('PyTorch Hub Cache', '~/.cache/torch'),
    ('User Logs', '~/Library/Logs'),
    ('Trash', '~/.Trash'),
    ('System Caches', '/Library/Caches'));
var
  Home: string;
  I: Integer;
begin
  Home := UserHomePath;
  SetLength(Result, Length(Entries));
  for I := 0 to High(Entries) do
  begin
    Result[I].Name := Entries[I, 0];
    Result[I].Path := Entries[I, 1];
    if Result[I].Path[1] = '~' then
      Result[I].Path := Home + Copy(Result[I].Path, 2, MaxInt);
  end;
end;
{$ELSE}
function CleanableCacheLocations: TCacheLocations;
begin
  Result := nil;
end;
{$ENDIF}

end.
