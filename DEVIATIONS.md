# Deviations from the Delphi SDK

This port tracks `bindist-api-delphi` unit by unit so the two can be diffed side by side:

```bash
diff ../bindist-api-delphi/BinDist.ClientV1.pas BinDist.ClientV1.pas
```

The following are identical: unit names, public types, interface GUIDs, method signatures, factory functions and the private method layout (`DoJsonRequest`, `DoDownload`, `DoBinaryPut`, `RaiseApiError`, `CodeFromStatus`, `ParseDateTime`, `Parse*`, `ParseJsonArray<T>`, `ExtractMeta`, `InternalDownloadToStream`).
`BinDist.Exceptions` and `BinDist.Factory` differ only by the `{$mode delphi}{$H+}` line. `BinDist.Interfaces` also swaps `System.SysUtils, System.Classes, System.Generics.Collections` for `SysUtils, Classes`.

Every other difference is listed below.

## Language and RTL gaps (forced by FPC 3.2.2)

| Where | Delphi | FPC | Why |
|---|---|---|---|
| all units | `System.*` dotted unit names | `SysUtils`, `Classes`, `fpjson`, `fphttpclient`, `opensslsockets`, `Generics.Collections` | FPC's RTL has no dotted namespaces. |
| all units | none | `{$mode delphi}{$H+}` | Delphi-compatible generics and syntax, with `AnsiString` strings. |
| ClientV1, AdminV1 | `ParseJsonArray<T>(…; Parser: TFunc<TJSONObject, T>)` | `Parser: TParserFunc<T>`, where `TParserFunc<T> = function(Json: TJSONObject): T of object` | FPC 3.2.2 has no anonymous methods or `TFunc`. Call sites are unchanged (`ParseJsonArray<TApplicationInfo>(AppsArray, ParseApplicationInfo)`). |
| ClientV1 `RaiseApiError`, AdminV1 `RaiseApiError`, AdminV1 `ListActivity`/`ListCustomers` (6 places) | inline `var X := …` and `for var I` | the variables are declared in the `var` block | FPC has no inline variables. |
| SmokeTest | 2 inline `var`s | declared in the `var` block | Same reason. |
| JSON | `System.JSON`: `TJSONValue`, `GetValue<T>(key, default)`, `GetValue(key)`, `X is TJSONObject`, `.Value`, `AddPair`, `TJSONNumber/TJSONBool.Create`, `ToString` | `fpjson`: `TJSONData`, `Get(key, default)`, `Find(key)`, `X.JSONType = jtObject`, `.AsString`, `Add`, plain values, `FormatJSON(AsCompressedJSON)` | Different library. The semantics are the same: a missing key or a value of the wrong type returns the default. `Int64` defaults are written `Int64(0)` to pick the Int64 overload. |
| JSON parsing | `TJSONObject.ParseJSONValue` (nil on bad JSON) | `ParseJSONValue` in `BinDist.FpcCompat` (nil on bad JSON) | fpjson's `GetJSON` raises on bad input. The wrapper keeps the "nil means invalid" contract that `DoJsonRequest` and `RaiseApiError` rely on. |
| dates | `System.DateUtils.ISO8601ToDate` | `ISO8601ToDate` / `TryISO8601ToDate` in `BinDist.FpcCompat` | Not in FPC 3.2.2. The name and default (`AReturnUTC = True`) are the same, so `ParseDateTime` is unchanged. Accepts `Z`, `±HH:MM`, `±HHMM`, fractional seconds (kept to ms), date-only and basic format. A time without a zone is taken as UTC. |
| hashing | `System.Hash.THashSHA2` | `THashSHA2` record in `BinDist.Sha256` | FPC 3.2.2 has no SHA-2. The record keeps the same `Create` / `Update` / `HashAsString` call shape, so `UploadLargeFile` is unchanged. |
| URL encoding | `TNetEncoding.URL.Encode` | `URLEncodeComponent` in `BinDist.FpcCompat` | Not available. It is RFC 3986 strict: only `A–Z a–z 0–9 - . _ ~` are left as-is, and space becomes `%20`. That is correct for both path segments and query values. The private `UrlEncode` wrapper method is kept. |
| base64 | `TNetEncoding.Base64.EncodeBytesToString` | `EncodeBytesBase64` in `BinDist.FpcCompat` (wraps the FCL `base64` unit) | Not available. It produces one unbroken line, like Delphi's `TBase64Encoding.Create(0)`. |

## HTTP layer (`DoJsonRequest`, `DoDownload`, `DoBinaryPut`)

`System.Net.HttpClient` becomes `fphttpclient` (`TFPHTTPClient`) plus `opensslsockets` for TLS.

1. **No `FHttpClient` field. A new `TFPHTTPClient` is created per request through the private method `CreateHttpClient`.**
   `TFPHTTPClient` stores request headers, body and response state on the instance, so sharing one would break the README's thread-safety promise. The constructor and destructor stay for diffability; the destructor is now empty.
2. **Same verb `case`, one call.** The `case Verb of hvGet: Get(...) ...` block becomes a `VerbNames[Verb]` lookup and a single `HTTPMethod(...)` call, because `TFPHTTPClient` has no `Patch` method. Passing `AllowedResponseCodes = []` means every status comes back to us, just as with Delphi's `IHTTPResponse`. The `StatusCode >= 400 → RaiseApiError` logic is unchanged.
3. **Settings matched to Delphi's `THTTPClient` defaults:** redirects are followed (`AllowRedirect := True`), and connect and IO timeouts are 60 s. FPC's defaults are no redirects, a 3 s connect timeout and an infinite IO timeout.
4. **`User-Agent: BinDist-FPC-Client/1.0` is sent.** Delphi sends its own default UA, but `fphttpclient` sends none, and some gateways and WAFs reject UA-less requests.
5. **Response body as UTF-8.** It is read into a `UTF8String` and parsed from there, so non-ASCII JSON survives on any system code page. `ContentAsString` did the charset decoding in Delphi.
6. **Compact request JSON.** `FormatJSON(AsCompressedJSON)` produces the same compact text as Delphi's `ToString`. fpjson's `AsJSON` would add spaces.

## Behaviour fixes (now also in Delphi)

These were found by `tests/TestClient` and have since been applied to the Delphi source, so they are no longer differences between the two:

1. The list endpoints send `limit` on the wire (not `pageSize`), and the public option is named `Limit` in both clients: `TListApplicationsOptions.Limit`, `ListActivity(…, Page, Limit)`, `ListCustomers(Page, Limit)`.
2. `Result.Pagination := Meta.Pagination` is assigned unconditionally, so responses without `meta.pagination` give a zeroed record instead of uninitialised integers.
3. Base64 upload content has no line breaks.
4. `DoDownload` buffers the body and copies it to the caller's stream only on HTTP 200, so an error body (e.g. S3 XML) is never written into the stream or file.

## Small internal changes

- `ParseStringArray` / `ParseJsonArray<T>` start with an extra `Result := nil;` line. This silences FPC's "managed result not initialised" warning and changes no behaviour.
- `examples/SmokeTest.lpr`: the `.dpr` has become an `.lpr`, and `{$APPTYPE CONSOLE}` is now Windows-only. `cwstring` is added on Unix. It only waits for Enter when `BINDIST_PAUSE` is set, so it can run unattended. The `in '..\…'` paths are replaced by `-Fu..`.

## FPC-only additions

`BinDist.Sha256.pas`, `BinDist.FpcCompat.pas`, `bindist_fpc.lpk` (Lazarus runtime package), `build.sh`, `tests/TestHelpers.lpr`, `tests/TestClient.lpr`.
