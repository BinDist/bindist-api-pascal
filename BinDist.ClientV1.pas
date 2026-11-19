unit BinDist.ClientV1;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpjson, fphttpclient, opensslsockets,
  Generics.Collections,
  BinDist.Interfaces, BinDist.Exceptions;

type
  THttpVerb = (hvGet, hvPost, hvPatch, hvDelete, hvPut);

  TParserFunc<T> = function(Json: TJSONObject): T of object;

  TBinDistClientV1 = class(TInterfacedObject, IBinDistClient)
  private
    FApiKey: string;
    FBaseUrl: string;

    function CreateHttpClient: TFPHTTPClient;

    // Internal HTTP layer
    function DoJsonRequest(Verb: THttpVerb; const Url: string;
      const Body: TJSONData;
      const Options: TRequestOptions): TJSONData;
    procedure DoDownload(const Url: string; Stream: TStream);

    // Response parsing helpers
    function ParseDateTime(const DateStr: string): TDateTime;
    function ParseStringArray(JsonArray: TJSONArray): TArray<string>;
    function ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
    function ParseVersionInfo(Json: TJSONObject): TVersionInfo;
    function ParseVersionFile(Json: TJSONObject): TVersionFile;
    function ParseDownloadInfo(Json: TJSONObject): TDownloadInfo;
    function ParseShareLink(Json: TJSONObject): TShareLink;
    function ParseJsonArray<T>(JsonArray: TJSONArray;
      Parser: TParserFunc<T>): TArray<T>;

    // URL helpers
    function BuildQueryString(
      const Params: TArray<TPair<string, string>>): string;
    function UrlEncode(const Value: string): string;

    // Error synthesis (matches Go's httpStatusCode + synthesizeError)
    class function CodeFromStatus(StatusCode: Integer): string; static;
    class procedure RaiseApiError(StatusCode: Integer;
      const ResponseBody: string; const RequestId: string); static;

    // Internal download + checksum
    procedure InternalDownloadToStream(const ApplicationId, Version: string;
      Stream: TStream; const Options: TRequestOptions;
      VerifyChecksum: Boolean; const FileId: string);
  public
    constructor Create(const BaseUrl, ApiKey: string);
    destructor Destroy; override;

    // IBinDistClient
    function ListApplications: TPaginatedResult<TArray<TApplicationInfo>>; overload;
    function ListApplications(const Options: TListApplicationsOptions):
      TPaginatedResult<TArray<TApplicationInfo>>; overload;

    function GetApplication(const ApplicationId: string): TApplicationInfo;

    function ListVersions(const ApplicationId: string):
      TPaginatedResult<TArray<TVersionInfo>>; overload;
    function ListVersions(const ApplicationId: string;
      const Options: TRequestOptions):
      TPaginatedResult<TArray<TVersionInfo>>; overload;

    function ListVersionFiles(const ApplicationId, Version: string):
      TPaginatedResult<TArray<TVersionFile>>;

    function GetDownloadInfo(const ApplicationId, Version: string;
      const FileId: string = ''): TDownloadInfo; overload;
    function GetDownloadInfo(const ApplicationId, Version, FileId: string;
      const Options: TRequestOptions): TDownloadInfo; overload;

    procedure DownloadFile(const ApplicationId, Version, OutputPath: string;
      VerifyChecksum: Boolean = True; const FileId: string = ''); overload;
    procedure DownloadFile(const ApplicationId, Version, OutputPath: string;
      const Options: TRequestOptions; VerifyChecksum: Boolean = True;
      const FileId: string = ''); overload;

    procedure DownloadFileToStream(const ApplicationId, Version: string;
      Stream: TStream; VerifyChecksum: Boolean = True;
      const FileId: string = ''); overload;
    procedure DownloadFileToStream(const ApplicationId, Version: string;
      Stream: TStream; const Options: TRequestOptions;
      VerifyChecksum: Boolean = True; const FileId: string = ''); overload;

    function CreateShareLink(const ApplicationId, Version: string;
      ExpiresMinutes: Integer; const FileId: string = ''): TShareLink;
  end;

implementation

uses
  BinDist.FpcCompat, BinDist.Sha256;

const
  HTTP_TIMEOUT_MS = 60000;
  USER_AGENT = 'BinDist-FPC-Client/1.0';

{ TBinDistClientV1 }

constructor TBinDistClientV1.Create(const BaseUrl, ApiKey: string);
begin
  inherited Create;
  FBaseUrl := BaseUrl;
  if FBaseUrl.EndsWith('/') then
    FBaseUrl := Copy(FBaseUrl, 1, Length(FBaseUrl) - 1);
  FApiKey := ApiKey;
end;

destructor TBinDistClientV1.Destroy;
begin
  inherited;
end;

function TBinDistClientV1.CreateHttpClient: TFPHTTPClient;
begin
  Result := TFPHTTPClient.Create(nil);
  Result.AllowRedirect := True;
  Result.ConnectTimeout := HTTP_TIMEOUT_MS;
  Result.IOTimeout := HTTP_TIMEOUT_MS;
  Result.AddHeader('User-Agent', USER_AGENT);
end;

// ---------------------------------------------------------------------------
// Error synthesis — matches Go's httpStatusCode table
// ---------------------------------------------------------------------------

class function TBinDistClientV1.CodeFromStatus(StatusCode: Integer): string;
begin
  case StatusCode of
    400: Result := 'bad_request';
    401: Result := 'unauthorized';
    403: Result := 'forbidden';
    404: Result := 'not_found';
    409: Result := 'conflict';
    429: Result := 'rate_limited';
  else
    if StatusCode >= 500 then
      Result := 'server_error'
    else
      Result := 'http_error';
  end;
end;

class procedure TBinDistClientV1.RaiseApiError(StatusCode: Integer;
  const ResponseBody: string; const RequestId: string);
var
  Json: TJSONData;
  ErrVal, MetaVal, TopErr: TJSONData;
  ErrorObj: TJSONObject;
  Code, Msg: string;
  ReqId: string;
begin
  Code := '';
  Msg := '';
  ReqId := RequestId;

  Json := ParseJSONValue(ResponseBody);
  if Assigned(Json) then
  try
    if Json is TJSONObject then
    begin
      // 1. Standard envelope: {"success":false,"error":{"code":"...","message":"..."}}
      ErrVal := TJSONObject(Json).Find('error');
      if Assigned(ErrVal) and (ErrVal.JSONType = jtObject) then
      begin
        ErrorObj := TJSONObject(ErrVal);
        Code := ErrorObj.Get('code', '');
        Msg := ErrorObj.Get('message', '');
      end;

      // Extract requestId from meta if present
      if ReqId = '' then
      begin
        MetaVal := TJSONObject(Json).Find('meta');
        if Assigned(MetaVal) and (MetaVal.JSONType = jtObject) then
          ReqId := TJSONObject(MetaVal).Get('requestId', '');
      end;

      // 2. Bare {"message":"..."} (auth middleware)
      if Msg = '' then
        Msg := TJSONObject(Json).Get('message', '');

      // 3. Bare {"error":"..."} (string error)
      if Msg = '' then
      begin
        TopErr := TJSONObject(Json).Find('error');
        if Assigned(TopErr) and (TopErr.JSONType = jtString) then
          Msg := TopErr.AsString;
      end;
    end;
  finally
    Json.Free;
  end;

  // 4. Fall back to generic message
  if Msg = '' then
    Msg := Format('HTTP %d error', [StatusCode]);

  if Code = '' then
    Code := CodeFromStatus(StatusCode);

  raise EBinDistApiError.Create(Code, Msg, StatusCode, ReqId);
end;

// ---------------------------------------------------------------------------
// Internal HTTP layer
// ---------------------------------------------------------------------------

function TBinDistClientV1.DoJsonRequest(Verb: THttpVerb; const Url: string;
  const Body: TJSONData; const Options: TRequestOptions): TJSONData;
const
  VerbNames: array[THttpVerb] of string = ('GET', 'POST', 'PATCH', 'DELETE', 'PUT');
var
  Http: TFPHTTPClient;
  BodyStream: TStringStream;
  ResponseStream: TStringStream;
  StatusCode: Integer;
  ResponseBody: UTF8String;
begin
  BodyStream := nil;
  ResponseStream := nil;
  Http := CreateHttpClient;
  try
    Http.AddHeader('Authorization', 'Bearer ' + FApiKey);
    Http.AddHeader('Content-Type', 'application/json');
    if Options.Channel <> '' then
      Http.AddHeader('X-Channel', Options.Channel);

    if Assigned(Body) then
    begin
      BodyStream := TStringStream.Create(Body.FormatJSON(AsCompressedJSON));
      Http.RequestBody := BodyStream;
    end;

    ResponseStream := TStringStream.Create('');
    try
      Http.HTTPMethod(VerbNames[Verb], Url, ResponseStream, []);
    except
      on E: Exception do
        raise EBinDistTransportError.Create(E.Message);
    end;

    StatusCode := Http.ResponseStatusCode;
    ResponseBody := UTF8String(ResponseStream.DataString);
    SetCodePage(RawByteString(ResponseBody), CP_UTF8, False);

    if StatusCode >= 400 then
      RaiseApiError(StatusCode, string(ResponseBody), '');

    Result := ParseJSONValue(ResponseBody);
    if not Assigned(Result) then
      raise EBinDistTransportError.Create('Invalid JSON response');

  finally
    ResponseStream.Free;
    BodyStream.Free;
    Http.Free;
  end;
end;

procedure TBinDistClientV1.DoDownload(const Url: string; Stream: TStream);
var
  Http: TFPHTTPClient;
  Buffer: TMemoryStream;
begin
  // Buffer the body so an error response (e.g. S3 XML for an expired
  // pre-signed URL) is never written into the caller's stream.
  Buffer := TMemoryStream.Create;
  Http := CreateHttpClient;
  try
    try
      // No auth header — downloading from pre-signed S3 URL
      Http.HTTPMethod('GET', Url, Buffer, []);
    except
      on E: Exception do
        raise EBinDistTransportError.Create(E.Message);
    end;

    if Http.ResponseStatusCode <> 200 then
      raise EBinDistTransportError.CreateFmt('download failed with status %d',
        [Http.ResponseStatusCode]);

    if Buffer.Size > 0 then
    begin
      Buffer.Position := 0;
      Stream.CopyFrom(Buffer, Buffer.Size);
    end;
  finally
    Http.Free;
    Buffer.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

function TBinDistClientV1.ParseDateTime(const DateStr: string): TDateTime;
begin
  if DateStr <> '' then
  begin
    try
      Result := ISO8601ToDate(DateStr);
    except
      Result := 0;
    end;
  end
  else
    Result := 0;
end;

function TBinDistClientV1.ParseStringArray(JsonArray: TJSONArray): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  if not Assigned(JsonArray) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, JsonArray.Count);
  for I := 0 to JsonArray.Count - 1 do
    Result[I] := JsonArray.Items[I].AsString;
end;

function TBinDistClientV1.ParseJsonArray<T>(JsonArray: TJSONArray;
  Parser: TParserFunc<T>): TArray<T>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, JsonArray.Count);
  for I := 0 to JsonArray.Count - 1 do
    Result[I] := Parser(JsonArray.Items[I] as TJSONObject);
end;


function TBinDistClientV1.ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
var
  TagsVal: TJSONData;
begin
  Result.ApplicationId := Json.Get('applicationId', '');
  Result.Name := Json.Get('name', '');
  Result.Description := Json.Get('description', '');
  Result.IsActive := Json.Get('isActive', True);
  Result.CreatedAt := ParseDateTime(Json.Get('createdAt', ''));
  Result.UpdatedAt := ParseDateTime(Json.Get('updatedAt', ''));
  TagsVal := Json.Find('tags');
  if Assigned(TagsVal) and (TagsVal.JSONType = jtArray) then
    Result.Tags := ParseStringArray(TJSONArray(TagsVal))
  else
    SetLength(Result.Tags, 0);
end;

function TBinDistClientV1.ParseVersionInfo(Json: TJSONObject): TVersionInfo;
begin
  Result.VersionId := Json.Get('versionId', '');
  Result.ApplicationId := Json.Get('applicationId', '');
  Result.Version := Json.Get('version', '');
  Result.ReleaseNotes := Json.Get('releaseNotes', '');
  Result.IsActive := Json.Get('isActive', True);
  Result.IsEnabled := Json.Get('isEnabled', True);
  Result.CreatedAt := ParseDateTime(Json.Get('createdAt', ''));
  Result.UpdatedAt := ParseDateTime(Json.Get('updatedAt', ''));
  Result.FileSize := Json.Get('fileSize', Int64(0));
  Result.DownloadCount := Json.Get('downloadCount', 0);
end;

function TBinDistClientV1.ParseVersionFile(Json: TJSONObject): TVersionFile;
begin
  Result.FileId := Json.Get('fileId', '');
  Result.FileName := Json.Get('fileName', '');
  Result.FileType := Json.Get('fileType', '');
  Result.FileSize := Json.Get('fileSize', Int64(0));
  Result.Checksum := Json.Get('checksum', '');
  Result.Order := Json.Get('order', 0);
  Result.Description := Json.Get('description', '');
end;

function TBinDistClientV1.ParseDownloadInfo(Json: TJSONObject): TDownloadInfo;
begin
  Result.DownloadId := Json.Get('downloadId', '');
  Result.Url := Json.Get('url', '');
  Result.ExpiresAt := ParseDateTime(Json.Get('expiresAt', ''));
  Result.FileName := Json.Get('fileName', '');
  Result.FileSize := Json.Get('fileSize', Int64(0));
  Result.Checksum := Json.Get('checksum', '');
end;

function TBinDistClientV1.ParseShareLink(Json: TJSONObject): TShareLink;
begin
  Result.ShareUrl := Json.Get('shareUrl', '');
  Result.ExpiresAt := ParseDateTime(Json.Get('expiresAt', ''));
end;

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

function TBinDistClientV1.UrlEncode(const Value: string): string;
begin
  Result := URLEncodeComponent(Value);
end;

function TBinDistClientV1.BuildQueryString(
  const Params: TArray<TPair<string, string>>): string;
var
  Pair: TPair<string, string>;
  First: Boolean;
begin
  Result := '';
  First := True;
  for Pair in Params do
  begin
    if Pair.Value <> '' then
    begin
      if First then
      begin
        Result := '?';
        First := False;
      end
      else
        Result := Result + '&';
      Result := Result + Pair.Key + '=' + UrlEncode(Pair.Value);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Helper to extract meta/pagination from a standard API response
// ---------------------------------------------------------------------------

type
  TResponseMeta = record
    RequestId: string;
    Pagination: TPagination;
    HasPagination: Boolean;
  end;

function ExtractMeta(Json: TJSONObject): TResponseMeta;
var
  MetaObj: TJSONObject;
  MetaVal, PagVal: TJSONData;
begin
  Result.RequestId := '';
  Result.HasPagination := False;
  Result.Pagination := Default(TPagination);

  MetaVal := Json.Find('meta');
  if Assigned(MetaVal) and (MetaVal.JSONType = jtObject) then
  begin
    MetaObj := TJSONObject(MetaVal);
    Result.RequestId := MetaObj.Get('requestId', '');
    PagVal := MetaObj.Find('pagination');
    if Assigned(PagVal) and (PagVal.JSONType = jtObject) then
    begin
      Result.HasPagination := True;
      Result.Pagination.Page := TJSONObject(PagVal).Get('page', 1);
      Result.Pagination.Limit := TJSONObject(PagVal).Get('limit', 20);
      Result.Pagination.Total := TJSONObject(PagVal).Get('total', 0);
      Result.Pagination.HasNext := TJSONObject(PagVal).Get('hasNext', False);
      Result.Pagination.HasPrevious := TJSONObject(PagVal).Get('hasPrevious', False);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// IBinDistClient — Customer methods
// ---------------------------------------------------------------------------

function TBinDistClientV1.ListApplications: TPaginatedResult<TArray<TApplicationInfo>>;
var
  EmptyOpts: TListApplicationsOptions;
begin
  EmptyOpts := Default(TListApplicationsOptions);
  Result := ListApplications(EmptyOpts);
end;

function TBinDistClientV1.ListApplications(
  const Options: TListApplicationsOptions): TPaginatedResult<TArray<TApplicationInfo>>;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
  AppsArray: TJSONArray;
  Meta: TResponseMeta;
  DefaultOpts: TRequestOptions;
begin
  SetLength(Params, 0);

  if Options.Page > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('page', IntToStr(Options.Page));
  end;

  if Options.Limit > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('limit', IntToStr(Options.Limit));
  end;

  if Options.Search <> '' then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('search', Options.Search);
  end;

  if Length(Options.Tags) > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('tags',
      string.Join(',', Options.Tags));
  end;

  RequestUrl := Format('%s/v1/applications%s', [FBaseUrl, BuildQueryString(Params)]);
  DefaultOpts := Default(TRequestOptions);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, DefaultOpts);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    AppsArray := DataObj.Find('applications') as TJSONArray;
    if Assigned(AppsArray) then
      Result.Items := ParseJsonArray<TApplicationInfo>(AppsArray, ParseApplicationInfo)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistClientV1.GetApplication(
  const ApplicationId: string): TApplicationInfo;
var
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
  DefaultOpts: TRequestOptions;
begin
  RequestUrl := Format('%s/v1/applications/%s',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  DefaultOpts := Default(TRequestOptions);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, DefaultOpts);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseApplicationInfo(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistClientV1.ListVersions(
  const ApplicationId: string): TPaginatedResult<TArray<TVersionInfo>>;
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  Result := ListVersions(ApplicationId, DefaultOpts);
end;

function TBinDistClientV1.ListVersions(const ApplicationId: string;
  const Options: TRequestOptions): TPaginatedResult<TArray<TVersionInfo>>;
var
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
  VersionsArray: TJSONArray;
  Meta: TResponseMeta;
begin
  RequestUrl := Format('%s/v1/applications/%s/versions',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, Options);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    VersionsArray := DataObj.Find('versions') as TJSONArray;
    if Assigned(VersionsArray) then
      Result.Items := ParseJsonArray<TVersionInfo>(VersionsArray, ParseVersionInfo)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistClientV1.ListVersionFiles(
  const ApplicationId, Version: string): TPaginatedResult<TArray<TVersionFile>>;
var
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
  FilesArray: TJSONArray;
  Meta: TResponseMeta;
  DefaultOpts: TRequestOptions;
begin
  RequestUrl := Format('%s/v1/applications/%s/versions/%s/files',
    [FBaseUrl, UrlEncode(ApplicationId), UrlEncode(Version)]);
  DefaultOpts := Default(TRequestOptions);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, DefaultOpts);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    FilesArray := DataObj.Find('files') as TJSONArray;
    if Assigned(FilesArray) then
      Result.Items := ParseJsonArray<TVersionFile>(FilesArray, ParseVersionFile)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistClientV1.GetDownloadInfo(const ApplicationId, Version: string;
  const FileId: string): TDownloadInfo;
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  Result := GetDownloadInfo(ApplicationId, Version, FileId, DefaultOpts);
end;

function TBinDistClientV1.GetDownloadInfo(const ApplicationId, Version,
  FileId: string; const Options: TRequestOptions): TDownloadInfo;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
begin
  SetLength(Params, 2);
  Params[0] := TPair<string, string>.Create('applicationId', ApplicationId);
  Params[1] := TPair<string, string>.Create('version', Version);

  if FileId <> '' then
  begin
    SetLength(Params, 3);
    Params[2] := TPair<string, string>.Create('fileId', FileId);
  end;

  RequestUrl := Format('%s/v1/downloads/url%s',
    [FBaseUrl, BuildQueryString(Params)]);
  Json := DoJsonRequest(hvGet, RequestUrl, nil, Options);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseDownloadInfo(DataObj);
  finally
    Json.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Download with checksum verification
// ---------------------------------------------------------------------------

procedure TBinDistClientV1.InternalDownloadToStream(
  const ApplicationId, Version: string; Stream: TStream;
  const Options: TRequestOptions; VerifyChecksum: Boolean;
  const FileId: string);
var
  Info: TDownloadInfo;
  TempStream: TMemoryStream;
  Hash: THashSHA2;
  Buf: TBytes;
  ActualChecksum: string;
begin
  Info := GetDownloadInfo(ApplicationId, Version, FileId, Options);

  if VerifyChecksum and (Info.Checksum <> '') then
  begin
    // Download to temp memory stream for checksum verification
    TempStream := TMemoryStream.Create;
    try
      DoDownload(Info.Url, TempStream);

      // Compute SHA256 from downloaded bytes
      TempStream.Position := 0;
      SetLength(Buf, TempStream.Size);
      if TempStream.Size > 0 then
        TempStream.ReadBuffer(Buf[0], TempStream.Size);

      Hash := THashSHA2.Create;
      Hash.Update(Buf, Length(Buf));
      ActualChecksum := LowerCase(Hash.HashAsString);

      if ActualChecksum <> LowerCase(Info.Checksum) then
        raise EBinDistChecksumMismatch.Create(Info.Checksum, ActualChecksum);

      // Copy to target stream
      TempStream.Position := 0;
      Stream.CopyFrom(TempStream, TempStream.Size);
    finally
      TempStream.Free;
    end;
  end
  else
    DoDownload(Info.Url, Stream);
end;

procedure TBinDistClientV1.DownloadFile(const ApplicationId, Version,
  OutputPath: string; VerifyChecksum: Boolean; const FileId: string);
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  DownloadFile(ApplicationId, Version, OutputPath, DefaultOpts,
    VerifyChecksum, FileId);
end;

procedure TBinDistClientV1.DownloadFile(const ApplicationId, Version,
  OutputPath: string; const Options: TRequestOptions;
  VerifyChecksum: Boolean; const FileId: string);
var
  FileStream: TFileStream;
  Dir, TempPath, BackupPath: string;
  Guid: TGUID;
begin
  Dir := ExtractFilePath(OutputPath);
  if (Dir <> '') and not DirectoryExists(Dir) then
    ForceDirectories(Dir);

  // Download into a temp file next to OutputPath and rename it into place
  // only after the download (and checksum) succeeded, so a failure never
  // leaves an empty or truncated file at OutputPath.
  CreateGUID(Guid);
  TempPath := OutputPath + '.' + Copy(GUIDToString(Guid), 2, 8) + '.part';

  try
    FileStream := TFileStream.Create(TempPath, fmCreate);
    try
      InternalDownloadToStream(ApplicationId, Version, FileStream, Options,
        VerifyChecksum, FileId);
    finally
      FileStream.Free;
    end;

    // RenameFile does not overwrite on every platform, so move the old file
    // aside first and put it back if the new one cannot be moved into place.
    BackupPath := '';
    if FileExists(OutputPath) then
    begin
      BackupPath := OutputPath + '.' + Copy(GUIDToString(Guid), 2, 8) + '.old';
      if not RenameFile(OutputPath, BackupPath) then
        raise EBinDistError.CreateFmt('cannot replace existing file %s',
          [OutputPath]);
    end;
    if not RenameFile(TempPath, OutputPath) then
    begin
      if BackupPath <> '' then
        RenameFile(BackupPath, OutputPath);
      raise EBinDistError.CreateFmt('cannot move downloaded file to %s',
        [OutputPath]);
    end;
    if BackupPath <> '' then
      DeleteFile(BackupPath);
  except
    DeleteFile(TempPath);
    raise;
  end;
end;

procedure TBinDistClientV1.DownloadFileToStream(const ApplicationId,
  Version: string; Stream: TStream; VerifyChecksum: Boolean;
  const FileId: string);
var
  DefaultOpts: TRequestOptions;
begin
  DefaultOpts := Default(TRequestOptions);
  DownloadFileToStream(ApplicationId, Version, Stream, DefaultOpts,
    VerifyChecksum, FileId);
end;

procedure TBinDistClientV1.DownloadFileToStream(const ApplicationId,
  Version: string; Stream: TStream; const Options: TRequestOptions;
  VerifyChecksum: Boolean; const FileId: string);
begin
  InternalDownloadToStream(ApplicationId, Version, Stream, Options,
    VerifyChecksum, FileId);
end;

// ---------------------------------------------------------------------------
// CreateShareLink
// ---------------------------------------------------------------------------

function TBinDistClientV1.CreateShareLink(const ApplicationId, Version: string;
  ExpiresMinutes: Integer; const FileId: string): TShareLink;
var
  Payload: TJSONObject;
  Json: TJSONData;
  DataObj: TJSONObject;
  DefaultOpts: TRequestOptions;
begin
  Payload := TJSONObject.Create;
  try
    Payload.Add('applicationId', ApplicationId);
    Payload.Add('version', Version);
    Payload.Add('expiresMinutes', ExpiresMinutes);
    if FileId <> '' then
      Payload.Add('fileId', FileId);

    DefaultOpts := Default(TRequestOptions);
    Json := DoJsonRequest(hvPost, FBaseUrl + '/v1/downloads/share',
      Payload, DefaultOpts);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseShareLink(DataObj);
  finally
    Json.Free;
  end;
end;

end.
