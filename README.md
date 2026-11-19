# BinDist Free Pascal SDK

Free Pascal client library for the [BinDist](https://bindist.eu) binary distribution API. Provides both a **customer client** (list applications, download files, verify checksums) and an **admin client** (create applications, upload versions, manage customers).

This is a port of the [Delphi SDK](https://github.com/BinDist/bindist-api-delphi). It keeps the same unit names, types, interfaces, GUIDs and method signatures, so code written against one compiles against the other. Where the FPC version differs, and why, is listed in [DEVIATIONS.md](DEVIATIONS.md).

## Requirements

- **Free Pascal 3.2.2 or later** (Lazarus optional). Only FCL packages are used (`fcl-web`, `fcl-json`, `fcl-base`, `rtl-generics`); there are no third-party dependencies.
- **OpenSSL at runtime** for HTTPS (`opensslsockets`):
  - **Linux**: `libssl` / `libcrypto` (OpenSSL 1.1 or 3.x), e.g. `apt install libssl3`. These are loaded dynamically at runtime.
  - **macOS**: an OpenSSL install, e.g. `brew install openssl@3`. The system LibreSSL stub is not enough. If the libraries are not found, put them on `DYLD_LIBRARY_PATH` or next to the executable.
  - **Windows**: `libssl-3-x64.dll` / `libcrypto-3-x64.dll` (or the 1.1 equivalents) next to the executable or on `PATH`.
  Without OpenSSL, HTTPS calls raise `EBinDistTransportError`.

## Installation

Add the units to your project's search path (`-Fu<path>`), or open `bindist_fpc.lpk` in Lazarus and add it as a requirement of your project:

- `BinDist.Exceptions.pas` — Exception hierarchy
- `BinDist.Interfaces.pas` — Interfaces and type definitions
- `BinDist.ClientV1.pas` — Customer client implementation
- `BinDist.AdminV1.pas` — Admin client implementation
- `BinDist.Factory.pas` — Factory functions
- `BinDist.Sha256.pas` — SHA-256 (FPC 3.2.2 ships none). FPC only.
- `BinDist.FpcCompat.pas` — ISO-8601 parser, URL/base64 encoding, JSON parse helper. FPC only.

The units use `{$mode delphi}{$H+}`. Your own code may use any mode; the examples below are written in `{$mode delphi}`. In `objfpc` mode, write `specialize TPaginatedResult<...>`.

### Strings and Unicode

`string` is `AnsiString` in `{$mode delphi}`. JSON is decoded from UTF-8 and converted to the string's code page, so:

- **Unix**: add `cwstring` to your program's `uses` clause. Without it, non-ASCII text can be garbled.
- **Windows**: use a UTF-8 code page for non-ASCII names. Lazarus LCL apps already do this. For console apps, set `DefaultSystemCodePage := CP_UTF8` at startup.

## Building and testing this repository

```bash
./build.sh                      # compiles units, example and tests with -Sew, then runs the tests
FPC=/path/to/fpc ./build.sh     # use a specific compiler
```

Or by hand:

```bash
fpc -Fu. -FUlib -FEexamples examples/SmokeTest.lpr
BINDIST_API_KEY=... ./examples/SmokeTest      # optional BINDIST_BASE_URL
```

- `tests/TestHelpers` runs known-answer tests for SHA-256 (FIPS 180 vectors, padding boundaries, chunked updates), ISO-8601 parsing, URL encoding and base64.
- `tests/TestClient` runs both clients against an in-process HTTP mock on 127.0.0.1. It checks paths, query names (`limit`), the `Authorization` and `X-Channel` headers, JSON bodies, envelope and pagination parsing, every branch of the error fallback, checksum verification, redirects, and that pre-signed URLs receive no auth header. It needs no network access.

## API Key Format

The shape of the API key depends on the deployment:

- **Hosted** (`api.bindist.eu`, multi-tenant): `{tenant_id}.{secret}` — tenant ID and secret joined by a dot.
- **Self-hosted** (single-tenant): just the secret. No tenant prefix needed.

The SDK does not validate the key — it is passed verbatim in the `Authorization: Bearer` header.

## Quick Start — Customer Client

```pascal
uses
  BinDist.Interfaces, BinDist.Factory, BinDist.Exceptions;

var
  Client: IBinDistClient;
  Apps: TPaginatedResult<TArray<TApplicationInfo>>;
  App: TApplicationInfo;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  try
    Apps := Client.ListApplications;
    for App in Apps.Items do
      WriteLn(App.Name);
  except
    on E: EBinDistApiError do
      WriteLn(Format('API error [%s]: %s', [E.Code, E.Message]));
    on E: EBinDistTransportError do
      WriteLn('Network error: ' + E.Message);
  end;
end;
```

## Listing Versions (with Channel)

```pascal
var
  Client: IBinDistClient;
  Opts: TRequestOptions;
  Versions: TPaginatedResult<TArray<TVersionInfo>>;
  V: TVersionInfo;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  // Production channel (default)
  Versions := Client.ListVersions('myapp');

  // Test channel — includes disabled/pre-release versions
  Opts.Channel := 'Test';
  Versions := Client.ListVersions('myapp', Opts);

  for V in Versions.Items do
    WriteLn(Format('%s (enabled=%s)', [V.Version, BoolToStr(V.IsEnabled, True)]));
end;
```

## Downloading a File

`DownloadFile` internally calls `GetDownloadInfo` to obtain the pre-signed URL, downloads the bytes, and verifies the SHA256 checksum by default. The file is written to a temporary `<OutputPath>.<random>.part` file in the same directory and renamed into place only on success, so a failed download or checksum mismatch never leaves a partial file at `OutputPath` (an existing file there is kept until the new one is complete).

```pascal
var
  Client: IBinDistClient;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  try
    // Downloads with checksum verification (default)
    Client.DownloadFile('myapp', '1.0.0', '/tmp/myapp.exe');
  except
    on E: EBinDistChecksumMismatch do
      WriteLn(Format('Checksum failed: expected %s, got %s', [E.Expected, E.Actual]));
    on E: EBinDistApiError do
      WriteLn('API error: ' + E.Message);
  end;
end;
```

To download without checksum verification:

```pascal
Client.DownloadFile('myapp', '1.0.0', '/tmp/myapp.exe',
  False {VerifyChecksum});
```

To download a specific file in a multi-file version:

```pascal
Client.DownloadFile('myapp', '1.0.0', '/tmp/patch.exe',
  True {VerifyChecksum}, 'file-id-here');
```

## Download to Stream

```pascal
var
  Client: IBinDistClient;
  Stream: TMemoryStream;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  Stream := TMemoryStream.Create;
  try
    Client.DownloadFileToStream('myapp', '1.0.0', Stream);
    WriteLn('Downloaded ', Stream.Size, ' bytes');
  finally
    Stream.Free;
  end;
end;
```

## Share Links

```pascal
var
  Client: IBinDistClient;
  Link: TShareLink;
begin
  Client := CreateBinDistClient('https://api.bindist.eu', 'your-api-key');

  Link := Client.CreateShareLink('myapp', '1.0.0', 60 {minutes});
  WriteLn('Share URL: ' + Link.ShareUrl);
end;
```

## Admin Client

```pascal
uses
  BinDist.Interfaces, BinDist.Factory, BinDist.Exceptions;

var
  Admin: IBinDistAdmin;
  App: TApplicationInfo;
  Upload: TUploadResult;
  CreateOpts: TCreateApplicationOptions;
  Content: TBytes;
begin
  Admin := CreateBinDistAdminClient('https://api.bindist.eu', 'admin-api-key');

  // Create an application
  CreateOpts.ApplicationId := 'myapp';
  CreateOpts.Name := 'My Application';
  SetLength(CreateOpts.CustomerIds, 1);
  CreateOpts.CustomerIds[0] := 'customer-id';
  App := Admin.CreateApplication(CreateOpts);

  // Upload a small file (< 10 MB)
  Content := ReadFileBytes('/build/myapp');  // your own helper, e.g. via TFileStream
  Upload := Admin.UploadSmallFile('myapp', '1.0.0', 'myapp.exe', Content,
    'Initial release');

  // Upload a large file (>= 10 MB) — uses multi-step S3 upload
  Upload := Admin.UploadLargeFile('myapp', '2.0.0', 'myapp.exe', Content,
    'Major update');

  // Update version metadata (VerOpts: TUpdateVersionOptions)
  VerOpts := Default(TUpdateVersionOptions);
  VerOpts.IsEnabledSet := True;
  VerOpts.IsEnabled := True;
  Admin.UpdateVersion('myapp', '1.0.0', VerOpts);

  // Get application stats (admin-only) (Stats: TStats)
  Stats := Admin.GetStats('myapp');
  WriteLn('Total downloads: ', Stats.TotalDownloads);

  // Delete an application
  Admin.DeleteApplication('old-app');
end;
```

## Error Handling

All methods raise exceptions on failure — no `Success` field to check:

| Exception | When |
|---|---|
| `EBinDistApiError` | Server returned a non-2xx response. Inspect `Code`, `StatusCode`, `RequestId`. |
| `EBinDistTransportError` | Network failure, timeout, or malformed response. |
| `EBinDistChecksumMismatch` | Downloaded file's SHA256 doesn't match. Inspect `Expected`, `Actual`. |

```pascal
try
  Client.DownloadFile('myapp', '1.0.0', OutputPath);
except
  on E: EBinDistChecksumMismatch do
    // Handle checksum mismatch
  on E: EBinDistApiError do
  begin
    if SameText(E.Code, 'not_found') then
      // Handle not found
    else if SameText(E.Code, 'unauthorized') then
      // Handle auth failure
    else
      // Handle other API errors
  end;
  on E: EBinDistTransportError do
    // Handle network errors
end;
```

`Code` is whatever the server sent in its error envelope (SCREAMING_SNAKE, e.g. `NOT_FOUND`) or, when the body is not an envelope, a code synthesized from the HTTP status (lowercase: `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `rate_limited`, `server_error`, `http_error`). Compare case-insensitively (`SameText`) or use `StatusCode`.

## Thread Safety

The client is thread-safe. A single `IBinDistClient` or `IBinDistAdmin` instance can be shared across threads: each call creates its own `TFPHTTPClient`, and no fields are modified after construction. On Unix, multi-threaded programs must list `cthreads` first in the program's `uses` clause (standard FPC requirement).

## License

See [LICENSE](LICENSE).
