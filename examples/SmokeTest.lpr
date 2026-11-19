program SmokeTest;

{$mode delphi}{$H+}
{$IFDEF WINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

// Build: fpc -Fu.. -FUlib examples/SmokeTest.lpr   (see README)

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils,
  Classes,
  BinDist.Interfaces,
  BinDist.Exceptions,
  BinDist.Factory;

procedure Run;
var
  BaseUrl, ApiKey: string;
  Client: IBinDistClient;
  Apps: TPaginatedResult<TArray<TApplicationInfo>>;
  App: TApplicationInfo;
  Versions: TPaginatedResult<TArray<TVersionInfo>>;
  V: TVersionInfo;
  Files: TPaginatedResult<TArray<TVersionFile>>;
  F: TVersionFile;
  FileName: string;
  OutputPath: string;
begin
  BaseUrl := GetEnvironmentVariable('BINDIST_BASE_URL');
  ApiKey := GetEnvironmentVariable('BINDIST_API_KEY');

  if BaseUrl = '' then
    BaseUrl := 'https://api.bindist.eu';

  if ApiKey = '' then
  begin
    WriteLn('Set BINDIST_API_KEY environment variable to run this test.');
    WriteLn('Optionally set BINDIST_BASE_URL (defaults to https://api.bindist.eu).');
    Exit;
  end;

  Client := CreateBinDistClient(BaseUrl, ApiKey);

  // --- List applications ---
  WriteLn('=== Applications ===');
  Apps := Client.ListApplications;
  WriteLn(Format('Found %d application(s) (requestId: %s)',
    [Length(Apps.Items), Apps.RequestId]));
  for App in Apps.Items do
    WriteLn(Format('  %s - %s (active=%s)',
      [App.ApplicationId, App.Name, BoolToStr(App.IsActive, True)]));
  WriteLn;

  if Length(Apps.Items) = 0 then
  begin
    WriteLn('No applications found. Nothing more to test.');
    Exit;
  end;

  // Use the first application for further tests
  App := Apps.Items[0];

  // --- Get single application ---
  WriteLn('=== GetApplication ===');
  App := Client.GetApplication(App.ApplicationId);
  WriteLn(Format('  %s: %s', [App.ApplicationId, App.Name]));
  WriteLn;

  // --- List versions ---
  WriteLn('=== Versions ===');
  Versions := Client.ListVersions(App.ApplicationId);
  WriteLn(Format('Found %d version(s)', [Length(Versions.Items)]));
  for V in Versions.Items do
    WriteLn(Format('  %s  enabled=%s  active=%s  size=%d',
      [V.Version, BoolToStr(V.IsEnabled, True),
       BoolToStr(V.IsActive, True), V.FileSize]));
  WriteLn;

  if Length(Versions.Items) = 0 then
  begin
    WriteLn('No versions found. Nothing more to test.');
    Exit;
  end;

  // --- List version files ---
  WriteLn('=== Version Files ===');
  Files := Client.ListVersionFiles(App.ApplicationId,
    Versions.Items[0].Version);
  WriteLn(Format('Found %d file(s)', [Length(Files.Items)]));
  for F in Files.Items do
    WriteLn(Format('  %s  %s  %d bytes  checksum=%s',
      [F.FileId, F.FileName, F.FileSize, F.Checksum]));
  WriteLn;

  // --- Download highest version (first in list), using original filename ---
  WriteLn('=== Download ===');
  V := Versions.Items[0];
  if Length(Files.Items) > 0 then
    FileName := Files.Items[0].FileName
  else
    FileName := App.ApplicationId + '-' + V.Version;
  OutputPath := IncludeTrailingPathDelimiter(GetCurrentDir) + FileName;
  WriteLn(Format('Downloading %s v%s to %s ...', [App.ApplicationId, V.Version, OutputPath]));
  Client.DownloadFile(App.ApplicationId, V.Version, OutputPath);
  WriteLn(Format('  Done — %d bytes, checksum verified.', [V.FileSize]));
  WriteLn;

  WriteLn('All smoke tests passed.');
end;

begin
  try
    Run;
  except
    on E: EBinDistApiError do
      WriteLn(Format('API error [%s] (HTTP %d): %s',
        [E.Code, E.StatusCode, E.Message]));
    on E: EBinDistTransportError do
      WriteLn('Transport error: ' + E.Message);
    on E: Exception do
      WriteLn('Unexpected error: ' + E.ClassName + ': ' + E.Message);
  end;

  // The Delphi version waits for Enter; on FPC this is a console tool,
  // so only pause when asked to (e.g. when launched from an IDE).
  if GetEnvironmentVariable('BINDIST_PAUSE') <> '' then
  begin
    WriteLn;
    WriteLn('Press Enter to exit...');
    ReadLn;
  end;
end.
