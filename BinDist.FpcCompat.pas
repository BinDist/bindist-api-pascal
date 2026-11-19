unit BinDist.FpcCompat;

{ Small stand-ins for Delphi RTL routines that Free Pascal 3.2.2 lacks or
  spells differently. Kept in one unit so BinDist.ClientV1 / BinDist.AdminV1
  can keep the same call sites as the Delphi sources:

    Delphi                                FPC (this unit)
    ------------------------------------  ------------------------------------
    System.DateUtils.ISO8601ToDate        ISO8601ToDate / TryISO8601ToDate
    TJSONObject.ParseJSONValue            ParseJSONValue (nil on bad JSON)
    TNetEncoding.URL.Encode               URLEncodeComponent
    TNetEncoding.Base64.EncodeBytesToString  EncodeBytesBase64 }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpjson;

/// Parses an ISO-8601 / RFC 3339 timestamp such as
/// 2026-01-02T03:04:05.123Z, 2026-01-02T03:04:05+02:00 or 2026-01-02.
/// Like Delphi's ISO8601ToDate, the default returns UTC; with
/// AReturnUTC = False the value is converted to local time.
/// A timestamp without a zone designator is taken as UTC.
function TryISO8601ToDate(const S: string; out Value: TDateTime;
  AReturnUTC: Boolean = True): Boolean;
/// Raises EConvertError on malformed input.
function ISO8601ToDate(const S: string; AReturnUTC: Boolean = True): TDateTime;

/// Parses JSON text; returns nil (instead of raising) when it is not valid
/// JSON, matching Delphi's TJSONObject.ParseJSONValue. Caller owns the result.
function ParseJSONValue(const S: UTF8String): TJSONData;

/// RFC 3986 percent-encoding of the UTF-8 bytes of Value. Only the
/// unreserved set A-Z a-z 0-9 - . _ ~ is left as-is (space -> %20), so the
/// result is safe both as a path segment and as a query value.
function URLEncodeComponent(const Value: string): string;

function EncodeBytesBase64(const Data: TBytes): string;

implementation

uses
  DateUtils, base64, jsonparser, jsonscanner;

function TryISO8601ToDate(const S: string; out Value: TDateTime;
  AReturnUTC: Boolean): Boolean;
var
  P, Len: Integer;

  function ReadDigits(Count: Integer; out N: Integer): Boolean;
  var
    I: Integer;
  begin
    N := 0;
    Result := False;
    if P + Count - 1 > Len then
      Exit;
    for I := 0 to Count - 1 do
    begin
      if not (S[P + I] in ['0'..'9']) then
        Exit;
      N := N * 10 + (Ord(S[P + I]) - Ord('0'));
    end;
    Inc(P, Count);
    Result := True;
  end;

  function Accept(C: Char): Boolean;
  begin
    Result := (P <= Len) and (S[P] = C);
    if Result then
      Inc(P);
  end;

var
  Y, Mo, D, H, Mi, Sec, Ms, OffH, OffM, Digits, Frac: Integer;
  Sign: Integer;
  Basic: Boolean;
  Date, Time: TDateTime;
begin
  Value := 0;
  Result := False;
  Len := Length(S);
  P := 1;
  H := 0; Mi := 0; Sec := 0; Ms := 0;
  Sign := 0; OffH := 0; OffM := 0;

  // Date: YYYY-MM-DD or YYYYMMDD
  if not ReadDigits(4, Y) then
    Exit;
  Basic := not Accept('-');
  if not ReadDigits(2, Mo) then
    Exit;
  if not Basic and not Accept('-') then
    Exit;
  if not ReadDigits(2, D) then
    Exit;

  // Time: [T| ]HH[:MM[:SS[.fff...]]]
  if (P <= Len) and (S[P] in ['T', 't', ' ']) then
  begin
    Inc(P);
    if not ReadDigits(2, H) then
      Exit;
    if (P <= Len) and (S[P] in [':', '0'..'9']) then
    begin
      if not Basic and not Accept(':') then
        Exit;
      if not ReadDigits(2, Mi) then
        Exit;
      if (P <= Len) and (S[P] in [':', '0'..'9']) then
      begin
        if not Basic and not Accept(':') then
          Exit;
        if not ReadDigits(2, Sec) then
          Exit;
        if (P <= Len) and (S[P] in ['.', ',']) then
        begin
          Inc(P);
          // Keep millisecond precision, ignore further digits.
          Digits := 0;
          Frac := 0;
          while (P <= Len) and (S[P] in ['0'..'9']) do
          begin
            if Digits < 3 then
            begin
              Frac := Frac * 10 + (Ord(S[P]) - Ord('0'));
              Inc(Digits);
            end;
            Inc(P);
          end;
          if Digits = 0 then
            Exit;
          while Digits < 3 do
          begin
            Frac := Frac * 10;
            Inc(Digits);
          end;
          Ms := Frac;
        end;
      end;
    end;

    // Zone: Z | +HH[:MM] | -HH[:MM] | +HHMM
    if (P <= Len) and (S[P] in ['Z', 'z']) then
      Inc(P)
    else if (P <= Len) and (S[P] in ['+', '-']) then
    begin
      if S[P] = '+' then Sign := 1 else Sign := -1;
      Inc(P);
      if not ReadDigits(2, OffH) then
        Exit;
      if P <= Len then
      begin
        Accept(':');
        if not ReadDigits(2, OffM) then
          Exit;
      end;
      if (OffH > 23) or (OffM > 59) then
        Exit;
    end;
  end;

  if P <= Len then
    Exit; // trailing garbage

  // 24:00:00 is not accepted; leap seconds (60) are clamped to 59.
  if Sec = 60 then
    Sec := 59;
  if not TryEncodeDate(Y, Mo, D, Date) then
    Exit;
  if not TryEncodeTime(H, Mi, Sec, Ms, Time) then
    Exit;

  Value := Date + Time;
  if Sign <> 0 then
    Value := IncMinute(Value, -Sign * (OffH * 60 + OffM));

  if not AReturnUTC then
    Value := UniversalTimeToLocal(Value);
  Result := True;
end;

function ISO8601ToDate(const S: string; AReturnUTC: Boolean): TDateTime;
begin
  if not TryISO8601ToDate(S, Result, AReturnUTC) then
    raise EConvertError.CreateFmt('"%s" is not a valid ISO 8601 date/time', [S]);
end;

function ParseJSONValue(const S: UTF8String): TJSONData;
begin
  try
    Result := GetJSON(S, True);
  except
    on EJSONParser do
      Result := nil;
    on EScannerError do
      Result := nil;
  end;
end;

function URLEncodeComponent(const Value: string): string;
const
  HexChars: array[0..15] of Char = '0123456789ABCDEF';
var
  Utf8: UTF8String;
  I, J: Integer;
  C: AnsiChar;
begin
  Utf8 := UTF8String(Value);
  Result := '';
  SetLength(Result, Length(Utf8) * 3);
  J := 0;
  for I := 1 to Length(Utf8) do
  begin
    C := Utf8[I];
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
    begin
      Inc(J);
      Result[J] := C;
    end
    else
    begin
      Result[J + 1] := '%';
      Result[J + 2] := HexChars[Ord(C) shr 4];
      Result[J + 3] := HexChars[Ord(C) and $0F];
      Inc(J, 3);
    end;
  end;
  SetLength(Result, J);
end;

function EncodeBytesBase64(const Data: TBytes): string;
var
  Raw: RawByteString;
begin
  Raw := '';
  SetLength(Raw, Length(Data));
  if Length(Data) > 0 then
    Move(Data[0], Raw[1], Length(Data));
  Result := EncodeStringBase64(Raw);
end;

end.
