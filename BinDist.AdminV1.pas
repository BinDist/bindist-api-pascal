unit BinDist.AdminV1;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpjson, fphttpclient, opensslsockets,
  Generics.Collections,
  BinDist.Interfaces, BinDist.Exceptions;

type
  THttpVerb = (hvGet, hvPost, hvPatch, hvDelete, hvPut);

  TParserFunc<T> = function(Json: TJSONObject): T of object;

  TBinDistAdminV1 = class(TInterfacedObject, IBinDistAdmin)
  private
    FApiKey: string;
    FBaseUrl: string;

    function CreateHttpClient: TFPHTTPClient;

    // Internal HTTP layer (same pattern as TBinDistClientV1)
    function DoJsonRequest(Verb: THttpVerb; const Url: string;
      const Body: TJSONData): TJSONData;
    procedure DoBinaryPut(const Url: string; const Content: TBytes);

    // Parsing helpers
    function ParseDateTime(const DateStr: string): TDateTime;
    function ParseStringArray(JsonArray: TJSONArray): TArray<string>;
    function ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
    function ParseVersionInfo(Json: TJSONObject): TVersionInfo;
    function ParseCustomerInfo(Json: TJSONObject): TCustomerInfo;
    function ParseCreateCustomerResult(Json: TJSONObject): TCreateCustomerResult;
    function ParseUploadResult(Json: TJSONObject): TUploadResult;
    function ParseActivityEntry(Json: TJSONObject): TActivityEntry;
    function ParseJsonArray<T>(JsonArray: TJSONArray;
      Parser: TParserFunc<T>): TArray<T>;
    function UrlEncode(const Value: string): string;

    // Error synthesis
    class function CodeFromStatus(StatusCode: Integer): string; static;
    class procedure RaiseApiError(StatusCode: Integer;
      const ResponseBody: string; const RequestId: string); static;
  public
    constructor Create(const BaseUrl, ApiKey: string);
    destructor Destroy; override;

    // IBinDistAdmin
    function CreateCustomer(const Name: string;
      const ParentCustomerId: string = 'admin';
      const Notes: string = ''): TCreateCustomerResult;

    function CreateApplication(
      const Options: TCreateApplicationOptions): TApplicationInfo;

    function UploadSmallFile(const ApplicationId, Version, FileName: string;
      const Content: TBytes; const ReleaseNotes: string = ''): TUploadResult;

    function UploadLargeFile(const ApplicationId, Version, FileName: string;
      const Content: TBytes; const ReleaseNotes: string = ''): TUploadResult;

    function UpdateVersion(const ApplicationId, Version: string;
      const Options: TUpdateVersionOptions): TVersionInfo;

    function UpdateCustomer(const CustomerId: string;
      const Options: TUpdateCustomerOptions): TCustomerInfo;

    procedure DeleteApplication(const ApplicationId: string);

    function ListActivity(const ActivityType, ApplicationId: string;
      Page, Limit: Integer): TPaginatedResult<TArray<TActivityEntry>>;

    function ListCustomers(Page, Limit: Integer):
      TPaginatedResult<TArray<TCustomerInfo>>;

    function GetStats(const ApplicationId: string): TStats;
  end;

implementation

uses
  BinDist.FpcCompat, BinDist.Sha256;

const
  HTTP_TIMEOUT_MS = 60000;
  USER_AGENT = 'BinDist-FPC-Client/1.0';

type
  TResponseMeta = record
    RequestId: string;
    Pagination: TPagination;
    HasPagination: Boolean;
  end;

function ExtractMeta(Json: TJSONObject): TResponseMeta;
var
  MetaVal, PagVal: TJSONData;
  MetaObj: TJSONObject;
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

{ TBinDistAdminV1 }

constructor TBinDistAdminV1.Create(const BaseUrl, ApiKey: string);
begin
  inherited Create;
  FBaseUrl := BaseUrl;
  if FBaseUrl.EndsWith('/') then
    FBaseUrl := Copy(FBaseUrl, 1, Length(FBaseUrl) - 1);
  FApiKey := ApiKey;
end;

destructor TBinDistAdminV1.Destroy;
begin
  inherited;
end;

function TBinDistAdminV1.CreateHttpClient: TFPHTTPClient;
begin
  Result := TFPHTTPClient.Create(nil);
  Result.AllowRedirect := True;
  Result.ConnectTimeout := HTTP_TIMEOUT_MS;
  Result.IOTimeout := HTTP_TIMEOUT_MS;
  Result.AddHeader('User-Agent', USER_AGENT);
end;

// ---------------------------------------------------------------------------
// Error synthesis — same table as customer client
// ---------------------------------------------------------------------------

class function TBinDistAdminV1.CodeFromStatus(StatusCode: Integer): string;
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

class procedure TBinDistAdminV1.RaiseApiError(StatusCode: Integer;
  const ResponseBody: string; const RequestId: string);
var
  Json: TJSONData;
  ErrVal, MetaVal, TopErr: TJSONData;
  ErrorObj: TJSONObject;
  Code, Msg, ReqId: string;
begin
  Code := '';
  Msg := '';
  ReqId := RequestId;

  Json := ParseJSONValue(ResponseBody);
  if Assigned(Json) then
  try
    if Json is TJSONObject then
    begin
      ErrVal := TJSONObject(Json).Find('error');
      if Assigned(ErrVal) and (ErrVal.JSONType = jtObject) then
      begin
        ErrorObj := TJSONObject(ErrVal);
        Code := ErrorObj.Get('code', '');
        Msg := ErrorObj.Get('message', '');
      end;

      if ReqId = '' then
      begin
        MetaVal := TJSONObject(Json).Find('meta');
        if Assigned(MetaVal) and (MetaVal.JSONType = jtObject) then
          ReqId := TJSONObject(MetaVal).Get('requestId', '');
      end;

      if Msg = '' then
        Msg := TJSONObject(Json).Get('message', '');

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

  if Msg = '' then
    Msg := Format('HTTP %d error', [StatusCode]);
  if Code = '' then
    Code := CodeFromStatus(StatusCode);

  raise EBinDistApiError.Create(Code, Msg, StatusCode, ReqId);
end;

// ---------------------------------------------------------------------------
// Internal HTTP layer
// ---------------------------------------------------------------------------

function TBinDistAdminV1.DoJsonRequest(Verb: THttpVerb;
  const Url: string; const Body: TJSONData): TJSONData;
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

procedure TBinDistAdminV1.DoBinaryPut(const Url: string;
  const Content: TBytes);
var
  Http: TFPHTTPClient;
  Stream: TBytesStream;
  ResponseStream: TMemoryStream;
begin
  // No auth header — uploading to pre-signed S3 URL
  ResponseStream := nil;
  Stream := TBytesStream.Create(Content);
  Http := CreateHttpClient;
  try
    Http.AddHeader('Content-Type', 'application/octet-stream');
    Http.RequestBody := Stream;
    ResponseStream := TMemoryStream.Create;
    try
      Http.HTTPMethod('PUT', Url, ResponseStream, []);
    except
      on E: Exception do
        raise EBinDistTransportError.Create(E.Message);
    end;

    if Http.ResponseStatusCode <> 200 then
      raise EBinDistTransportError.CreateFmt('S3 upload failed with status %d',
        [Http.ResponseStatusCode]);
  finally
    ResponseStream.Free;
    Http.Free;
    Stream.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

function TBinDistAdminV1.ParseDateTime(const DateStr: string): TDateTime;
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

function TBinDistAdminV1.ParseStringArray(JsonArray: TJSONArray): TArray<string>;
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

function TBinDistAdminV1.ParseJsonArray<T>(JsonArray: TJSONArray;
  Parser: TParserFunc<T>): TArray<T>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, JsonArray.Count);
  for I := 0 to JsonArray.Count - 1 do
    Result[I] := Parser(JsonArray.Items[I] as TJSONObject);
end;


function TBinDistAdminV1.ParseApplicationInfo(Json: TJSONObject): TApplicationInfo;
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

function TBinDistAdminV1.ParseVersionInfo(Json: TJSONObject): TVersionInfo;
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

function TBinDistAdminV1.ParseCustomerInfo(Json: TJSONObject): TCustomerInfo;
begin
  Result.CustomerId := Json.Get('customerId', '');
  Result.Name := Json.Get('name', '');
  Result.ApiKey := Json.Get('apiKey', '');
  Result.IsActive := Json.Get('isActive', True);
  Result.Notes := Json.Get('notes', '');
  Result.CreatedAt := ParseDateTime(Json.Get('createdAt', ''));
end;

function TBinDistAdminV1.ParseCreateCustomerResult(Json: TJSONObject): TCreateCustomerResult;
begin
  Result.CustomerId := Json.Get('customerId', '');
  Result.ApiKey := Json.Get('apiKey', '');
  Result.Name := Json.Get('name', '');
  Result.CreatedAt := Json.Get('createdAt', '');
end;

function TBinDistAdminV1.ParseUploadResult(Json: TJSONObject): TUploadResult;
begin
  Result.Message := Json.Get('message', '');
  Result.VersionId := Json.Get('versionId', '');
  Result.ApplicationId := Json.Get('applicationId', '');
  Result.Version := Json.Get('version', '');
  Result.FileSize := Json.Get('fileSize', Int64(0));
  Result.Checksum := Json.Get('checksum', '');
end;

function TBinDistAdminV1.ParseActivityEntry(Json: TJSONObject): TActivityEntry;
begin
  Result.ActivityType := Json.Get('type', '');
  Result.ApplicationId := Json.Get('applicationId', '');
  Result.Version := Json.Get('version', '');
  Result.CustomerId := Json.Get('customerId', '');
  Result.Timestamp := ParseDateTime(Json.Get('timestamp', ''));
end;

function TBinDistAdminV1.UrlEncode(const Value: string): string;
begin
  Result := URLEncodeComponent(Value);
end;

// ---------------------------------------------------------------------------
// IBinDistAdmin implementation
// ---------------------------------------------------------------------------

function TBinDistAdminV1.CreateCustomer(const Name: string;
  const ParentCustomerId: string; const Notes: string): TCreateCustomerResult;
var
  Payload: TJSONObject;
  Json: TJSONData;
  DataObj: TJSONObject;
  Path: string;
begin
  Payload := TJSONObject.Create;
  try
    Payload.Add('name', Name);
    if Notes <> '' then
      Payload.Add('notes', Notes);

    Path := Format('%s/v1/management/customers/%s/apikeys',
      [FBaseUrl, UrlEncode(ParentCustomerId)]);
    Json := DoJsonRequest(hvPost, Path, Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseCreateCustomerResult(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.CreateApplication(
  const Options: TCreateApplicationOptions): TApplicationInfo;
var
  Payload: TJSONObject;
  CustArray, TagsArray: TJSONArray;
  Json: TJSONData;
  DataObj: TJSONObject;
  S: string;
begin
  Payload := TJSONObject.Create;
  try
    Payload.Add('applicationId', Options.ApplicationId);
    Payload.Add('name', Options.Name);

    if Length(Options.CustomerIds) > 0 then
    begin
      CustArray := TJSONArray.Create;
      for S in Options.CustomerIds do
        CustArray.Add(S);
      Payload.Add('customerIds', CustArray);
    end;

    if Options.Description <> '' then
      Payload.Add('description', Options.Description);

    if Length(Options.Tags) > 0 then
    begin
      TagsArray := TJSONArray.Create;
      for S in Options.Tags do
        TagsArray.Add(S);
      Payload.Add('tags', TagsArray);
    end;

    Json := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/applications', Payload);
  finally
    Payload.Free;
  end;

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

function TBinDistAdminV1.UploadSmallFile(const ApplicationId, Version,
  FileName: string; const Content: TBytes;
  const ReleaseNotes: string): TUploadResult;
var
  Payload: TJSONObject;
  Json: TJSONData;
  DataObj: TJSONObject;
begin
  Payload := TJSONObject.Create;
  try
    Payload.Add('applicationId', ApplicationId);
    Payload.Add('version', Version);
    Payload.Add('fileName', FileName);
    Payload.Add('fileContent',
      EncodeBytesBase64(Content));
    Payload.Add('fileType', 'MAIN');
    if ReleaseNotes <> '' then
      Payload.Add('releaseNotes', ReleaseNotes);

    Json := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/upload', Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseUploadResult(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.UploadLargeFile(const ApplicationId, Version,
  FileName: string; const Content: TBytes;
  const ReleaseNotes: string): TUploadResult;
var
  FileSize: Int64;
  Checksum: string;
  Hash: THashSHA2;
  // Step 1
  UrlPayload: TJSONObject;
  UrlJson: TJSONData;
  UrlDataObj: TJSONObject;
  UploadId, UploadUrl: string;
  // Step 3
  CompletePayload: TJSONObject;
  CompleteJson: TJSONData;
  CompleteDataObj: TJSONObject;
begin
  FileSize := Length(Content);

  // Compute SHA256 checksum
  Hash := THashSHA2.Create;
  Hash.Update(Content, Length(Content));
  Checksum := LowerCase(Hash.HashAsString);

  // Step 1: Get pre-signed upload URL
  UrlPayload := TJSONObject.Create;
  try
    UrlPayload.Add('applicationId', ApplicationId);
    UrlPayload.Add('version', Version);
    UrlPayload.Add('fileName', FileName);
    UrlPayload.Add('fileSize', FileSize);
    UrlPayload.Add('contentType', 'application/octet-stream');

    UrlJson := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/upload/large-url', UrlPayload);
  finally
    UrlPayload.Free;
  end;

  try
    if not (UrlJson is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    UrlDataObj := TJSONObject(UrlJson).Find('data') as TJSONObject;
    if not Assigned(UrlDataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    UploadId := UrlDataObj.Get('uploadId', '');
    UploadUrl := UrlDataObj.Get('uploadUrl', '');
  finally
    UrlJson.Free;
  end;

  // Step 2: PUT binary to S3
  DoBinaryPut(UploadUrl, Content);

  // Step 3: Complete the upload
  CompletePayload := TJSONObject.Create;
  try
    CompletePayload.Add('uploadId', UploadId);
    CompletePayload.Add('applicationId', ApplicationId);
    CompletePayload.Add('version', Version);
    CompletePayload.Add('fileName', FileName);
    CompletePayload.Add('fileSize', FileSize);
    CompletePayload.Add('checksum', Checksum);
    if ReleaseNotes <> '' then
      CompletePayload.Add('releaseNotes', ReleaseNotes);

    CompleteJson := DoJsonRequest(hvPost,
      FBaseUrl + '/v1/management/upload/large-complete', CompletePayload);
  finally
    CompletePayload.Free;
  end;

  try
    if not (CompleteJson is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    CompleteDataObj := TJSONObject(CompleteJson).Find('data') as TJSONObject;
    if not Assigned(CompleteDataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseUploadResult(CompleteDataObj);
  finally
    CompleteJson.Free;
  end;
end;

function TBinDistAdminV1.UpdateVersion(const ApplicationId, Version: string;
  const Options: TUpdateVersionOptions): TVersionInfo;
var
  Payload: TJSONObject;
  Json: TJSONData;
  DataObj: TJSONObject;
  Path: string;
begin
  Payload := TJSONObject.Create;
  try
    if Options.IsEnabledSet then
      Payload.Add('isEnabled', Options.IsEnabled);
    if Options.IsActiveSet then
      Payload.Add('isActive', Options.IsActive);
    if Options.ReleaseNotesSet then
      Payload.Add('releaseNotes', Options.ReleaseNotes);

    Path := Format('%s/v1/applications/%s/versions/%s',
      [FBaseUrl, UrlEncode(ApplicationId), UrlEncode(Version)]);
    Json := DoJsonRequest(hvPatch, Path, Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseVersionInfo(DataObj);
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.UpdateCustomer(const CustomerId: string;
  const Options: TUpdateCustomerOptions): TCustomerInfo;
var
  Payload: TJSONObject;
  Json: TJSONData;
  DataObj: TJSONObject;
  Path: string;
begin
  Payload := TJSONObject.Create;
  try
    if Options.NameSet then
      Payload.Add('name', Options.Name);
    if Options.IsActiveSet then
      Payload.Add('isActive', Options.IsActive);
    if Options.NotesSet then
      Payload.Add('notes', Options.Notes);

    Path := Format('%s/v1/management/customers/%s',
      [FBaseUrl, UrlEncode(CustomerId)]);
    Json := DoJsonRequest(hvPatch, Path, Payload);
  finally
    Payload.Free;
  end;

  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result := ParseCustomerInfo(DataObj);
  finally
    Json.Free;
  end;
end;

procedure TBinDistAdminV1.DeleteApplication(const ApplicationId: string);
var
  Path: string;
  Json: TJSONData;
begin
  Path := Format('%s/v1/management/applications/%s',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  Json := DoJsonRequest(hvDelete, Path, nil);
  Json.Free;
end;

function TBinDistAdminV1.ListActivity(const ActivityType,
  ApplicationId: string; Page, Limit: Integer):
  TPaginatedResult<TArray<TActivityEntry>>;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
  ActivitiesArray: TJSONArray;
  Meta: TResponseMeta;
  Query: string;
  I: Integer;
begin
  SetLength(Params, 0);

  if ActivityType <> '' then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('type', ActivityType);
  end;
  if ApplicationId <> '' then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('applicationId', ApplicationId);
  end;
  if Page > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('page', IntToStr(Page));
  end;
  if Limit > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('limit', IntToStr(Limit));
  end;

  // Build query string
  Query := '';
  if Length(Params) > 0 then
  begin
    Query := '?' + Params[0].Key + '=' + UrlEncode(Params[0].Value);
    for I := 1 to High(Params) do
      Query := Query + '&' + Params[I].Key + '=' + UrlEncode(Params[I].Value);
  end;

  RequestUrl := FBaseUrl + '/v1/activity' + Query;
  Json := DoJsonRequest(hvGet, RequestUrl, nil);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    ActivitiesArray := DataObj.Find('activities') as TJSONArray;
    if Assigned(ActivitiesArray) then
      Result.Items := ParseJsonArray<TActivityEntry>(ActivitiesArray, ParseActivityEntry)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.ListCustomers(Page, Limit: Integer):
  TPaginatedResult<TArray<TCustomerInfo>>;
var
  Params: TArray<TPair<string, string>>;
  RequestUrl, Query: string;
  Json: TJSONData;
  DataObj: TJSONObject;
  CustomersArray: TJSONArray;
  Meta: TResponseMeta;
  I: Integer;
begin
  SetLength(Params, 0);

  if Page > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('page', IntToStr(Page));
  end;
  if Limit > 0 then
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := TPair<string, string>.Create('limit', IntToStr(Limit));
  end;

  Query := '';
  if Length(Params) > 0 then
  begin
    Query := '?' + Params[0].Key + '=' + UrlEncode(Params[0].Value);
    for I := 1 to High(Params) do
      Query := Query + '&' + Params[I].Key + '=' + UrlEncode(Params[I].Value);
  end;

  RequestUrl := FBaseUrl + '/v1/management/customers' + Query;
  Json := DoJsonRequest(hvGet, RequestUrl, nil);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    CustomersArray := DataObj.Find('customers') as TJSONArray;
    if Assigned(CustomersArray) then
      Result.Items := ParseJsonArray<TCustomerInfo>(CustomersArray, ParseCustomerInfo)
    else
      SetLength(Result.Items, 0);

    Meta := ExtractMeta(TJSONObject(Json));
    Result.RequestId := Meta.RequestId;
    Result.Pagination := Meta.Pagination;
  finally
    Json.Free;
  end;
end;

function TBinDistAdminV1.GetStats(const ApplicationId: string): TStats;
var
  RequestUrl: string;
  Json: TJSONData;
  DataObj: TJSONObject;
begin
  RequestUrl := Format('%s/v1/applications/%s/stats',
    [FBaseUrl, UrlEncode(ApplicationId)]);
  Json := DoJsonRequest(hvGet, RequestUrl, nil);
  try
    if not (Json is TJSONObject) then
      raise EBinDistTransportError.Create('Unexpected response format');

    DataObj := TJSONObject(Json).Find('data') as TJSONObject;
    if not Assigned(DataObj) then
      raise EBinDistTransportError.Create('Missing data in response');

    Result.TotalDownloads := DataObj.Get('totalDownloads', 0);
  finally
    Json.Free;
  end;
end;

end.
