program TestClient;

{ End-to-end tests of TBinDistClientV1 / TBinDistAdminV1 against an
  in-process fphttpserver mock on 127.0.0.1. Verifies the wire contract
  (paths, query names, headers, JSON bodies), envelope/pagination parsing,
  the RaiseApiError fallback chain, checksum verification and the
  no-auth-on-presigned-URL rule. No network access needed.
  Exit code 0 = all passed. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  SysUtils, Classes, DateUtils, fpjson, jsonparser, base64,
  fphttpserver, httpdefs,
  BinDist.Interfaces, BinDist.Exceptions, BinDist.Factory, BinDist.Sha256;

const
  BLOB = 'hello bindist';
  // A 200-byte payload so the large-upload path carries real binary data.
  API_KEY = 'tenant-uuid.secret';

type
  TLastRequest = record
    Method: string;
    URI: string;
    Authorization: string;
    Channel: string;
    ContentType: string;
    Body: RawByteString;
  end;

  TMockServer = class
  public
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  end;

  // TFPHttpServer in 3.2.2 does not publish Address; bind to loopback only.
  TLocalServer = class(TFPHttpServer)
  public
    property Address;
  end;

  TServerThread = class(TThread)
  public
    Server: TLocalServer;
    procedure Execute; override;
  end;

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  Port: Word;
  BaseUrl: string;
  Last: TLastRequest;
  BlobRequest: TLastRequest;   // last request to /blob/* or /s3put
  Mock: TMockServer;

procedure Check(Cond: Boolean; const Name: string; const Detail: string = '');
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name, ' ', Detail);
  end;
end;

procedure CheckEq(const Actual, Expected, Name: string); overload;
begin
  Check(Actual = Expected, Name, Format('expected "%s", got "%s"', [Expected, Actual]));
end;

procedure CheckEq(Actual, Expected: Int64; const Name: string); overload;
begin
  Check(Actual = Expected, Name, Format('expected %d, got %d', [Expected, Actual]));
end;

function BytesOf(const S: RawByteString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function BlobSha: string;
begin
  Result := THashSHA2.GetHashString(BytesOf(BLOB));
end;

function LargePayload: RawByteString;
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, 200);
  for I := 1 to 200 do
    Result[I] := AnsiChar(I mod 256);
end;

{ TServerThread }

procedure TServerThread.Execute;
begin
  try
    Server.Active := True;  // blocks until Active := False
  except
    on E: Exception do
      WriteLn('server thread: ', E.Message);
  end;
end;

{ TMockServer }

procedure Send(AResponse: TFPHTTPConnectionResponse; Code: Integer;
  const Body: string; const ContentType: string = 'application/json');
begin
  AResponse.Code := Code;
  AResponse.ContentType := ContentType;
  // Content := would go through a TStringList and append a line ending,
  // which breaks the byte-exact checksum tests; use a raw stream instead.
  AResponse.FreeContentStream := True;
  AResponse.ContentStream := TStringStream.Create(Body);
  AResponse.ContentLength := Length(Body);
end;

const
  PAGINATION = '"pagination":{"page":2,"limit":5,"total":11,"hasNext":true,"hasPrevious":true}';
  APP_JSON = '{"applicationId":"app1","name":"App One","description":"d",' +
    '"isActive":false,"createdAt":"2026-01-02T03:04:05.123Z",' +
    '"updatedAt":"2026-01-03T00:00:00+01:00","tags":["x","y"]}';
  VERSION_JSON = '{"versionId":"v-1","applicationId":"app1","version":"1.2.3",' +
    '"releaseNotes":"notes","isActive":true,"isEnabled":false,' +
    '"createdAt":"2026-01-02T03:04:05Z","fileSize":5000000000,"downloadCount":7}';

procedure TMockServer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  R: TLastRequest;
  Path: string;
  Body: TJSONData;
begin
  R.Method := ARequest.Method;
  R.URI := ARequest.URI;
  R.Authorization := ARequest.Authorization;
  R.Channel := ARequest.GetCustomHeader('X-Channel');
  R.ContentType := ARequest.ContentType;
  R.Body := ARequest.Content;
  Path := ARequest.PathInfo;
  if Path = '' then
    Path := ARequest.URL;
  if Pos('?', Path) > 0 then
    Path := Copy(Path, 1, Pos('?', Path) - 1);

  if (Copy(Path, 1, 6) = '/blob/') or (Path = '/s3put') or (Path = '/redirect') then
    BlobRequest := R
  else
    Last := R;

  // --- presigned storage endpoints (no auth expected) ---
  if Path = '/blob/ok' then
    Send(AResponse, 200, BLOB, 'application/octet-stream')
  else if Path = '/redirect' then
  begin
    AResponse.Code := 302;
    AResponse.SetCustomHeader('Location', BaseUrl + '/blob/ok');
    AResponse.ContentLength := 0;
  end
  else if Path = '/blob/missing' then
    Send(AResponse, 403, '<Error><Code>AccessDenied</Code></Error>', 'application/xml')
  else if Path = '/s3put' then
  begin
    if (R.Body = LargePayload) and (R.Authorization = '') then
      Send(AResponse, 200, '', 'text/plain')
    else
      Send(AResponse, 400, 'bad upload', 'text/plain');
  end

  // --- error shapes ---
  else if Path = '/v1/applications/envelope-err' then
    Send(AResponse, 404, '{"success":false,"error":{"code":"NOT_FOUND","message":"no such app"},"meta":{"requestId":"req-404"}}')
  else if Path = '/v1/applications/bare-message' then
    Send(AResponse, 401, '{"message":"Unauthorized"}')
  else if Path = '/v1/applications/bare-error' then
    Send(AResponse, 429, '{"error":"slow down"}')
  else if Path = '/v1/applications/html-502' then
    Send(AResponse, 502, '<html>Bad Gateway</html>', 'text/html')
  else if Path = '/v1/applications/teapot' then
    Send(AResponse, 418, '')
  else if Path = '/v1/applications/not-json' then
    Send(AResponse, 200, 'this is not json', 'text/plain')

  // --- customer API ---
  else if Path = '/v1/applications' then
    Send(AResponse, 200, '{"success":true,"data":{"applications":[' + APP_JSON +
      ',{"applicationId":"app2","name":"Two"}]},"meta":{"requestId":"req-list",' + PAGINATION + '}}')
  else if (Path = '/v1/applications/app%2F1') or (Path = '/v1/applications/app/1') then
    Send(AResponse, 200, '{"success":true,"data":' + APP_JSON + '}')
  else if Path = '/v1/applications/app1/versions' then
    Send(AResponse, 200, '{"success":true,"data":{"versions":[' + VERSION_JSON + ']},"meta":{"requestId":"req-v"}}')
  else if Path = '/v1/applications/app1/versions/1.2.3/files' then
    Send(AResponse, 200, '{"success":true,"data":{"files":[{"fileId":"f1","fileName":"a.exe",' +
      '"fileType":"MAIN","fileSize":13,"checksum":"abc","order":1,"description":"main"}]}}')
  else if Path = '/v1/downloads/url' then
  begin
    if Pos('version=bad', R.URI) > 0 then
      Send(AResponse, 200, '{"success":true,"data":{"downloadId":"d1","url":"' + BaseUrl +
        '/blob/ok","checksum":"' + StringOfChar('0', 64) + '"}}')
    else if Pos('version=missing', R.URI) > 0 then
      Send(AResponse, 200, '{"success":true,"data":{"downloadId":"d1","url":"' + BaseUrl +
        '/blob/missing","checksum":""}}')
    else if Pos('version=redirect', R.URI) > 0 then
      Send(AResponse, 200, '{"success":true,"data":{"downloadId":"d1","url":"' + BaseUrl +
        '/redirect","checksum":"' + UpperCase(BlobSha) + '"}}')
    else
      Send(AResponse, 200, '{"success":true,"data":{"downloadId":"d1","url":"' + BaseUrl +
        '/blob/ok","expiresAt":"2026-01-02T03:34:05Z","fileName":"a.exe","fileSize":13,"checksum":"' +
        BlobSha + '"}}');
  end
  else if Path = '/v1/downloads/share' then
    Send(AResponse, 200, '{"success":true,"data":{"shareUrl":"https://x/s/abc","expiresAt":"2026-01-02T04:04:05Z"}}')

  // --- admin API ---
  else if Path = '/v1/management/customers/admin/apikeys' then
    Send(AResponse, 201, '{"success":true,"data":{"customerId":"c1","apiKey":"t.k","name":"Cust","createdAt":"2026-01-02T03:04:05Z"}}')
  else if Path = '/v1/management/applications' then
    Send(AResponse, 201, '{"success":true,"data":' + APP_JSON + '}')
  else if Path = '/v1/management/upload' then
    Send(AResponse, 201, '{"success":true,"data":{"message":"ok","versionId":"v9","applicationId":"app1","version":"2.0.0","fileSize":13,"checksum":"' + BlobSha + '"}}')
  else if Path = '/v1/management/upload/large-url' then
    Send(AResponse, 200, '{"success":true,"data":{"uploadId":"up-1","uploadUrl":"' + BaseUrl + '/s3put"}}')
  else if Path = '/v1/management/upload/large-complete' then
  begin
    Body := GetJSON(R.Body);
    try
      Send(AResponse, 201, '{"success":true,"data":{"message":"done","versionId":"v10","applicationId":"app1","version":"3.0.0",' +
        '"fileSize":' + IntToStr(TJSONObject(Body).Get('fileSize', 0)) + ',"checksum":"' +
        TJSONObject(Body).Get('checksum', '') + '"}}');
    finally
      Body.Free;
    end;
  end
  else if Path = '/v1/applications/app1/versions/1.2.3' then
    Send(AResponse, 200, '{"success":true,"data":' + VERSION_JSON + '}')
  else if Path = '/v1/management/customers/c1' then
    Send(AResponse, 200, '{"success":true,"data":{"customerId":"c1","name":"New","isActive":false,"notes":"n"}}')
  else if Path = '/v1/management/applications/old-app' then
    Send(AResponse, 200, '{"success":true,"data":null}')
  else if Path = '/v1/activity' then
    Send(AResponse, 200, '{"success":true,"data":{"activities":[{"type":"download","applicationId":"app1",' +
      '"version":"1.2.3","customerId":"c1","timestamp":"2026-01-02T03:04:05Z"}]},"meta":{' + PAGINATION + '}}')
  else if Path = '/v1/management/customers' then
    Send(AResponse, 200, '{"success":true,"data":{"customers":[{"customerId":"c1","name":"Cust"}]}}')
  else if Path = '/v1/applications/app1/stats' then
    Send(AResponse, 200, '{"success":true,"data":{"totalDownloads":42}}')
  else
    Send(AResponse, 404, '{"success":false,"error":{"code":"NOT_FOUND","message":"no route ' + Path + '"}}');
end;

// ---------------------------------------------------------------------------

procedure ExpectApiError(const AppId, ExpCode, ExpMsg: string; ExpStatus: Integer;
  const ExpReqId: string);
var
  Client: IBinDistClient;
  Raised: Boolean;
begin
  Client := CreateBinDistClient(BaseUrl, API_KEY);
  Raised := False;
  try
    Client.GetApplication(AppId);
  except
    on E: EBinDistApiError do
    begin
      Raised := True;
      CheckEq(E.Code, ExpCode, AppId + ' code');
      CheckEq(E.Message, ExpMsg, AppId + ' message');
      CheckEq(E.StatusCode, ExpStatus, AppId + ' status');
      CheckEq(E.RequestId, ExpReqId, AppId + ' requestId');
    end;
  end;
  Check(Raised, AppId + ' raised EBinDistApiError');
end;

procedure TestErrors;
var
  Client: IBinDistClient;
  Raised: Boolean;
begin
  ExpectApiError('envelope-err', 'NOT_FOUND', 'no such app', 404, 'req-404');
  ExpectApiError('bare-message', 'unauthorized', 'Unauthorized', 401, '');
  ExpectApiError('bare-error', 'rate_limited', 'slow down', 429, '');
  ExpectApiError('html-502', 'server_error', 'HTTP 502 error', 502, '');
  ExpectApiError('teapot', 'http_error', 'HTTP 418 error', 418, '');

  Client := CreateBinDistClient(BaseUrl, API_KEY);
  Raised := False;
  try
    Client.GetApplication('not-json');
  except
    on E: EBinDistTransportError do
      Raised := E.Message = 'Invalid JSON response';
  end;
  Check(Raised, 'non-JSON 200 -> EBinDistTransportError');

  // Nothing listens on port 1.
  Client := CreateBinDistClient('http://127.0.0.1:1', API_KEY);
  Raised := False;
  try
    Client.ListApplications;
  except
    on E: EBinDistTransportError do
      Raised := True;
  end;
  Check(Raised, 'connection refused -> EBinDistTransportError');
end;

function ReadFileContent(const Path: string): RawByteString;
var
  FS: TFileStream;
begin
  Result := '';
  FS := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

procedure WriteFileContent(const Path: string; const Content: RawByteString);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(Path, fmCreate);
  try
    if Length(Content) > 0 then
      FS.WriteBuffer(Content[1], Length(Content));
  finally
    FS.Free;
  end;
end;

function CountFiles(const Dir, Mask: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + Mask, faAnyFile, SR) = 0 then
  try
    repeat
      Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

// Counts leftover temp (*.part) and backup (*.old) files.
function CountLeftovers(const Dir: string): Integer;
begin
  Result := CountFiles(Dir, '*.part') + CountFiles(Dir, '*.old');
end;

// Runs DownloadFile and returns the exception class name ('' on success).
function TryDownloadFile(const Client: IBinDistClient;
  const Version, OutPath: string): string;
begin
  Result := '';
  try
    Client.DownloadFile('app1', Version, OutPath);
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

procedure TestDownloadFile;
var
  Client: IBinDistClient;
  Dir, OutPath: string;
begin
  Client := CreateBinDistClient(BaseUrl, API_KEY);
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'bindist-dl-' + IntToStr(GetProcessID);
  ForceDirectories(Dir);
  OutPath := IncludeTrailingPathDelimiter(Dir) + 'a.exe';
  try
    // (a) storage 403: no OutputPath, no .part/.old left behind.
    CheckEq(TryDownloadFile(Client, 'missing', OutPath), 'EBinDistTransportError', '(a) 403 raises transport error');
    Check(not FileExists(OutPath), '(a) 403 leaves no OutputPath');
    CheckEq(CountLeftovers(Dir), 0, '(a) 403 leaves no .part/.old file');

    // (b) checksum mismatch: same.
    CheckEq(TryDownloadFile(Client, 'bad', OutPath), 'EBinDistChecksumMismatch', '(b) mismatch raises');
    Check(not FileExists(OutPath), '(b) mismatch leaves no OutputPath');
    CheckEq(CountLeftovers(Dir), 0, '(b) mismatch leaves no .part/.old file');

    // (d) success: correct content, no .part/.old.
    CheckEq(TryDownloadFile(Client, '1.0.0', OutPath), '', '(d) success');
    CheckEq(ReadFileContent(OutPath), BLOB, '(d) content');
    CheckEq(CountLeftovers(Dir), 0, '(d) no .part/.old file');

    // (c) pre-existing file kept on failure, replaced on success.
    WriteFileContent(OutPath, 'old content');
    CheckEq(TryDownloadFile(Client, 'missing', OutPath), 'EBinDistTransportError', '(c) 403 raises');
    CheckEq(ReadFileContent(OutPath), 'old content', '(c) old file kept after 403');
    CheckEq(CountLeftovers(Dir), 0, '(c) no .part/.old after 403');
    CheckEq(TryDownloadFile(Client, 'bad', OutPath), 'EBinDistChecksumMismatch', '(c) mismatch raises');
    CheckEq(ReadFileContent(OutPath), 'old content', '(c) old file kept after mismatch');
    CheckEq(CountLeftovers(Dir), 0, '(c) no .part/.old after failures');
    CheckEq(TryDownloadFile(Client, '1.0.0', OutPath), '', '(c) success over existing');
    CheckEq(ReadFileContent(OutPath), BLOB, '(c) old file replaced');
    CheckEq(CountLeftovers(Dir), 0, '(c) no .part/.old after success');

    // Same with VerifyChecksum=False on 403 (no temp memory stream path).
    DeleteFile(OutPath);
    try
      Client.DownloadFile('app1', 'missing', OutPath, False);
    except
      on EBinDistTransportError do ;
    end;
    Check(not FileExists(OutPath), 'no-verify 403 leaves no OutputPath');
    CheckEq(CountLeftovers(Dir), 0, 'no-verify 403 leaves no .part/.old file');
  finally
    DeleteFile(OutPath);
    RemoveDir(Dir);
  end;
end;

procedure TestCustomer;
var
  Client: IBinDistClient;
  Opts: TListApplicationsOptions;
  Apps: TPaginatedResult<TArray<TApplicationInfo>>;
  App: TApplicationInfo;
  ReqOpts: TRequestOptions;
  Versions: TPaginatedResult<TArray<TVersionInfo>>;
  Files: TPaginatedResult<TArray<TVersionFile>>;
  Info: TDownloadInfo;
  Link: TShareLink;
  Stream: TMemoryStream;
  Body: TJSONData;
  Raised: Boolean;
  OutPath: string;
  Content: RawByteString;
begin
  // Trailing slash on the base URL is trimmed.
  Client := CreateBinDistClient(BaseUrl + '/', API_KEY);

  Opts := Default(TListApplicationsOptions);
  Opts.Page := 2;
  Opts.Limit := 5;
  Opts.Search := 'a b&c';
  Opts.Tags := ['x', 'y'];
  Apps := Client.ListApplications(Opts);
  CheckEq(Last.Method, 'GET', 'list method');
  CheckEq(Last.URI, '/v1/applications?page=2&limit=5&search=a%20b%26c&tags=x%2Cy', 'list query uses limit');
  CheckEq(Last.Authorization, 'Bearer ' + API_KEY, 'bearer auth');
  CheckEq(Last.Channel, '', 'no channel by default');
  CheckEq(Length(Apps.Items), 2, 'list count');
  CheckEq(Apps.RequestId, 'req-list', 'list requestId');
  CheckEq(Apps.Pagination.Page, 2, 'pagination page');
  CheckEq(Apps.Pagination.Limit, 5, 'pagination limit');
  CheckEq(Apps.Pagination.Total, 11, 'pagination total');
  Check(Apps.Pagination.HasNext and Apps.Pagination.HasPrevious, 'pagination flags');
  App := Apps.Items[0];
  CheckEq(App.ApplicationId, 'app1', 'app id');
  Check(not App.IsActive, 'app isActive false parsed');
  Check(SameDateTime(App.CreatedAt, EncodeDateTime(2026, 1, 2, 3, 4, 5, 123)), 'app createdAt');
  Check(SameDateTime(App.UpdatedAt, EncodeDateTime(2026, 1, 2, 23, 0, 0, 0)), 'app updatedAt offset');
  CheckEq(Length(App.Tags), 2, 'app tags');
  CheckEq(App.Tags[1], 'y', 'app tag value');
  // Defaults for missing keys.
  Check(Apps.Items[1].IsActive, 'missing isActive defaults to True');
  CheckEq(Apps.Items[1].Description, '', 'missing description -> empty');
  Check(Apps.Items[1].CreatedAt = 0, 'missing createdAt -> 0');
  CheckEq(Length(Apps.Items[1].Tags), 0, 'missing tags -> empty');

  Client.ListApplications;
  CheckEq(Last.URI, '/v1/applications', 'list without options has no query');

  App := Client.GetApplication('app/1');
  CheckEq(Last.URI, '/v1/applications/app%2F1', 'path segment encoded');
  CheckEq(App.Name, 'App One', 'get app name');

  ReqOpts.Channel := 'Test';
  Versions := Client.ListVersions('app1', ReqOpts);
  CheckEq(Last.Channel, 'Test', 'X-Channel header sent');
  Check(Pos('channel', LowerCase(Last.URI)) = 0, 'channel not in query');
  CheckEq(Versions.Items[0].FileSize, 5000000000, 'Int64 fileSize');
  CheckEq(Versions.Items[0].DownloadCount, 7, 'downloadCount');
  Check(not Versions.Items[0].IsEnabled, 'isEnabled false');
  CheckEq(Versions.RequestId, 'req-v', 'versions requestId');

  Files := Client.ListVersionFiles('app1', '1.2.3');
  CheckEq(Files.Items[0].FileId, 'f1', 'file id');
  CheckEq(Files.Items[0].Order, 1, 'file order');

  Info := Client.GetDownloadInfo('app1', '1.0.0', 'f 1');
  CheckEq(Last.URI, '/v1/downloads/url?applicationId=app1&version=1.0.0&fileId=f%201', 'download url query');
  CheckEq(Info.Checksum, BlobSha, 'download info checksum');

  // DownloadFileToStream with checksum verification; presigned GET has no auth.
  Stream := TMemoryStream.Create;
  try
    Client.DownloadFileToStream('app1', '1.0.0', Stream);
    CheckEq(Stream.Size, Length(BLOB), 'downloaded size');
    CheckEq(BlobRequest.Authorization, '', 'no auth header on presigned download');
    CheckEq(BlobRequest.URI, '/blob/ok', 'presigned url used');
  finally
    Stream.Free;
  end;

  // Redirect is followed; checksum comparison is case-insensitive.
  Stream := TMemoryStream.Create;
  try
    Client.DownloadFileToStream('app1', 'redirect', Stream);
    CheckEq(Stream.Size, Length(BLOB), 'redirected download size');
  finally
    Stream.Free;
  end;

  // Checksum mismatch.
  Stream := TMemoryStream.Create;
  Raised := False;
  try
    try
      Client.DownloadFileToStream('app1', 'bad', Stream);
    except
      on E: EBinDistChecksumMismatch do
      begin
        Raised := True;
        CheckEq(E.Actual, BlobSha, 'mismatch actual');
        CheckEq(E.Expected, StringOfChar('0', 64), 'mismatch expected');
      end;
    end;
    Check(Raised, 'checksum mismatch raised');
    CheckEq(Stream.Size, 0, 'nothing written on mismatch');
  finally
    Stream.Free;
  end;

  // Skipping verification on the same bad checksum succeeds.
  Stream := TMemoryStream.Create;
  try
    Client.DownloadFileToStream('app1', 'bad', Stream, False);
    CheckEq(Stream.Size, Length(BLOB), 'VerifyChecksum=False skips check');
  finally
    Stream.Free;
  end;

  // Storage 403: transport error, and the XML body is not written to the stream.
  Stream := TMemoryStream.Create;
  Raised := False;
  try
    try
      Client.DownloadFileToStream('app1', 'missing', Stream);
    except
      on E: EBinDistTransportError do
        Raised := E.Message = 'download failed with status 403';
    end;
    Check(Raised, 'storage 403 -> transport error');
    CheckEq(Stream.Size, 0, 'error body not written to stream');
  finally
    Stream.Free;
  end;

  // DownloadFile creates missing directories.
  OutPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'bindist-test-' + IntToStr(GetProcessID) + PathDelim + 'sub' + PathDelim + 'a.exe';
  Client.DownloadFile('app1', '1.0.0', OutPath);
  Check(FileExists(OutPath), 'DownloadFile wrote file');
  with TFileStream.Create(OutPath, fmOpenRead) do
  try
    Content := '';
    SetLength(Content, Size);
    ReadBuffer(Content[1], Size);
  finally
    Free;
  end;
  CheckEq(Content, BLOB, 'DownloadFile content');
  DeleteFile(OutPath);
  RemoveDir(ExtractFileDir(OutPath));
  RemoveDir(ExtractFileDir(ExtractFileDir(OutPath)));

  Link := Client.CreateShareLink('app1', '1.0.0', 60, 'f1');
  CheckEq(Last.Method, 'POST', 'share method');
  CheckEq(Last.URI, '/v1/downloads/share', 'share path');
  CheckEq(Last.ContentType, 'application/json', 'share content-type');
  Body := GetJSON(Last.Body);
  try
    CheckEq(Body.AsJSON, '{ "applicationId" : "app1", "version" : "1.0.0", "expiresMinutes" : 60, "fileId" : "f1" }', 'share body');
  finally
    Body.Free;
  end;
  CheckEq(Link.ShareUrl, 'https://x/s/abc', 'share url');
end;

procedure TestAdmin;
var
  Admin: IBinDistAdmin;
  Cust: TCreateCustomerResult;
  CreateOpts: TCreateApplicationOptions;
  App: TApplicationInfo;
  Upload: TUploadResult;
  VerOpts: TUpdateVersionOptions;
  CustOpts: TUpdateCustomerOptions;
  Ver: TVersionInfo;
  CustInfo: TCustomerInfo;
  Activity: TPaginatedResult<TArray<TActivityEntry>>;
  Customers: TPaginatedResult<TArray<TCustomerInfo>>;
  Body: TJSONData;
begin
  Admin := CreateBinDistAdminClient(BaseUrl, API_KEY);

  Cust := Admin.CreateCustomer('Cust', 'admin', 'some notes');
  CheckEq(Last.URI, '/v1/management/customers/admin/apikeys', 'create customer path');
  CheckEq(Last.Body, '{"name":"Cust","notes":"some notes"}', 'create customer body');
  CheckEq(Cust.ApiKey, 't.k', 'create customer apiKey');

  CreateOpts := Default(TCreateApplicationOptions);
  CreateOpts.ApplicationId := 'app1';
  CreateOpts.Name := 'App One';
  CreateOpts.CustomerIds := ['c1', 'c2'];
  CreateOpts.Tags := ['t'];
  App := Admin.CreateApplication(CreateOpts);
  CheckEq(Last.Body, '{"applicationId":"app1","name":"App One","customerIds":["c1","c2"],"tags":["t"]}', 'create app body');
  CheckEq(App.ApplicationId, 'app1', 'create app result');

  Upload := Admin.UploadSmallFile('app1', '2.0.0', 'a.exe', BytesOf(BLOB), 'rn');
  Body := GetJSON(Last.Body);
  try
    CheckEq(TJSONObject(Body).Get('fileContent', ''), EncodeStringBase64(BLOB), 'small upload base64');
    CheckEq(TJSONObject(Body).Get('fileType', ''), 'MAIN', 'small upload fileType');
    CheckEq(TJSONObject(Body).Get('releaseNotes', ''), 'rn', 'small upload notes');
  finally
    Body.Free;
  end;
  CheckEq(Upload.VersionId, 'v9', 'small upload result');

  Upload := Admin.UploadLargeFile('app1', '3.0.0', 'big.bin', BytesOf(LargePayload));
  CheckEq(BlobRequest.Method, 'PUT', 'large upload PUT');
  CheckEq(BlobRequest.Authorization, '', 'no auth on presigned PUT');
  CheckEq(BlobRequest.ContentType, 'application/octet-stream', 'PUT content-type');
  CheckEq(Last.URI, '/v1/management/upload/large-complete', 'large complete called');
  Body := GetJSON(Last.Body);
  try
    CheckEq(TJSONObject(Body).Get('uploadId', ''), 'up-1', 'complete uploadId');
    CheckEq(TJSONObject(Body).Get('checksum', ''),
      THashSHA2.GetHashString(BytesOf(LargePayload)), 'complete checksum');
    Check(TJSONObject(Body).Find('releaseNotes') = nil, 'empty releaseNotes omitted');
  finally
    Body.Free;
  end;
  CheckEq(Upload.FileSize, 200, 'large upload size');

  VerOpts := Default(TUpdateVersionOptions);
  VerOpts.IsEnabledSet := True;
  VerOpts.IsEnabled := False;
  Ver := Admin.UpdateVersion('app1', '1.2.3', VerOpts);
  CheckEq(Last.Method, 'PATCH', 'update version method');
  CheckEq(Last.Body, '{"isEnabled":false}', 'update version body');
  CheckEq(Ver.Version, '1.2.3', 'update version result');

  CustOpts := Default(TUpdateCustomerOptions);
  CustOpts.NameSet := True;
  CustOpts.Name := 'New';
  CustOpts.IsActiveSet := True;
  CustInfo := Admin.UpdateCustomer('c1', CustOpts);
  CheckEq(Last.Body, '{"name":"New","isActive":false}', 'update customer body');
  Check(not CustInfo.IsActive, 'update customer result');

  Admin.DeleteApplication('old-app');
  CheckEq(Last.Method, 'DELETE', 'delete method');
  CheckEq(Last.URI, '/v1/management/applications/old-app', 'delete path');

  Activity := Admin.ListActivity('download', 'app1', 2, 5);
  CheckEq(Last.URI, '/v1/activity?type=download&applicationId=app1&page=2&limit=5', 'activity query uses limit');
  CheckEq(Activity.Items[0].ActivityType, 'download', 'activity type');
  CheckEq(Activity.Pagination.Total, 11, 'activity pagination');

  Customers := Admin.ListCustomers(1, 50);
  CheckEq(Last.URI, '/v1/management/customers?page=1&limit=50', 'customers query uses limit');
  CheckEq(Customers.Items[0].CustomerId, 'c1', 'customers result');
  CheckEq(Customers.Pagination.Total, 0, 'no pagination meta -> zeroed');

  CheckEq(Admin.GetStats('app1').TotalDownloads, 42, 'stats');
end;

var
  ServerThread: TServerThread;
begin
  Randomize;
  Port := StrToIntDef(GetEnvironmentVariable('BINDIST_TEST_PORT'), 20000 + Random(20000));
  BaseUrl := 'http://127.0.0.1:' + IntToStr(Port);

  Mock := TMockServer.Create;
  ServerThread := TServerThread.Create(True);
  ServerThread.FreeOnTerminate := False;
  ServerThread.Server := TLocalServer.Create(nil);
  ServerThread.Server.Address := '127.0.0.1';
  ServerThread.Server.Port := Port;
  ServerThread.Server.OnRequest := Mock.HandleRequest;
  ServerThread.Start;
  Sleep(300);

  try
    TestErrors;
    TestCustomer;
    TestDownloadFile;
    TestAdmin;
  except
    on E: Exception do
    begin
      Inc(Failures);
      WriteLn('UNEXPECTED: ', E.ClassName, ': ', E.Message);
    end;
  end;

  WriteLn(Format('%d checks, %d failure(s)', [Checks, Failures]));
  // The listener blocks in accept(); exit without a graceful join.
  if Failures > 0 then
    Halt(1);
  Halt(0);
end.
