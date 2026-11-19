program TestHelpers;

{ Known-answer tests for the FPC-only helpers: BinDist.Sha256 (FIPS 180-4 /
  NIST CAVS vectors) and BinDist.FpcCompat (ISO-8601 parsing, URL encoding,
  base64). Exit code 0 = all passed. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils, DateUtils, BinDist.Sha256, BinDist.FpcCompat;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Name: string; const Detail: string = '');
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name, ' ', Detail);
  end;
end;

procedure CheckEq(const Actual, Expected, Name: string);
begin
  Check(Actual = Expected, Name, Format('expected "%s", got "%s"', [Expected, Actual]));
end;

function BytesOf(const S: RawByteString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function Sha(const S: RawByteString): string;
begin
  Result := THashSHA2.GetHashString(BytesOf(S));
end;

procedure TestSha256;
var
  Hash: THashSHA2;
  Data: TBytes;
  I, Split: Integer;
  Expected: string;
begin
  CheckEq(Sha(''),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'sha256 empty');
  CheckEq(Sha('abc'),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256 abc');
  CheckEq(Sha('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', 'sha256 448-bit');
  CheckEq(Sha('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu'),
    'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1', 'sha256 896-bit');
  CheckEq(Sha('The quick brown fox jumps over the lazy dog'),
    'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592', 'sha256 fox');

  // Padding boundaries: 55, 56, 63, 64, 65 bytes.
  CheckEq(Sha(StringOfChar('a', 55)),
    '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318', 'sha256 55xa');
  CheckEq(Sha(StringOfChar('a', 56)),
    'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a', 'sha256 56xa');
  CheckEq(Sha(StringOfChar('a', 63)),
    '7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34', 'sha256 63xa');
  CheckEq(Sha(StringOfChar('a', 64)),
    'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb', 'sha256 64xa');
  CheckEq(Sha(StringOfChar('a', 65)),
    '635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0', 'sha256 65xa');

  // One million 'a' (FIPS 180-2 appendix B.3), fed in uneven chunks.
  Expected := 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';
  CheckEq(Sha(StringOfChar('a', 1000000)), Expected, 'sha256 1M a (one shot)');
  Data := BytesOf(StringOfChar('a', 1000));
  Hash := THashSHA2.Create;
  for I := 1 to 1000 do
  begin
    Split := (I * 7) mod 1000;
    Hash.Update(Data[0], Split);
    Hash.Update(Data[Split], 1000 - Split);
  end;
  CheckEq(Hash.HashAsString, Expected, 'sha256 1M a (chunked)');
  // HashAsString must not consume the state.
  CheckEq(Hash.HashAsString, Expected, 'sha256 HashAsString idempotent');

  // Delphi call-site shape: Update(TBytes, Length).
  Hash := THashSHA2.Create;
  Hash.Update(BytesOf('abc'), 3);
  CheckEq(Hash.HashAsString,
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256 Update(TBytes,Len)');
end;

procedure CheckDate(const S: string; Y, Mo, D, H, Mi, Sec, Ms: Word);
var
  V: TDateTime;
begin
  Check(TryISO8601ToDate(S, V), 'iso8601 parse ' + S);
  // Compare at millisecond resolution (offset maths is floating point).
  Check(SameDateTime(V, EncodeDateTime(Y, Mo, D, H, Mi, Sec, Ms)), 'iso8601 value ' + S,
    'got ' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', V));
end;

procedure CheckBadDate(const S: string);
var
  V: TDateTime;
begin
  Check(not TryISO8601ToDate(S, V), 'iso8601 reject "' + S + '"');
end;

procedure TestIso8601;
var
  Raised: Boolean;
begin
  CheckDate('2026-01-02T03:04:05.123Z', 2026, 1, 2, 3, 4, 5, 123);
  CheckDate('2026-01-02T03:04:05Z', 2026, 1, 2, 3, 4, 5, 0);
  CheckDate('2026-01-02T03:04:05.1Z', 2026, 1, 2, 3, 4, 5, 100);
  CheckDate('2026-01-02T03:04:05.123456789Z', 2026, 1, 2, 3, 4, 5, 123);
  CheckDate('2026-01-02T03:04:05', 2026, 1, 2, 3, 4, 5, 0);
  CheckDate('2026-01-02T03:04Z', 2026, 1, 2, 3, 4, 0, 0);
  CheckDate('2026-01-02', 2026, 1, 2, 0, 0, 0, 0);
  CheckDate('20260102T030405Z', 2026, 1, 2, 3, 4, 5, 0);
  // Offsets are normalised to UTC.
  CheckDate('2026-01-02T03:04:05+02:00', 2026, 1, 2, 1, 4, 5, 0);
  CheckDate('2026-01-02T03:04:05-05:30', 2026, 1, 2, 8, 34, 5, 0);
  CheckDate('2026-01-01T01:00:00+0200', 2025, 12, 31, 23, 0, 0, 0);
  CheckDate('2024-02-29T23:59:59.999Z', 2024, 2, 29, 23, 59, 59, 999);

  CheckBadDate('');
  CheckBadDate('not a date');
  CheckBadDate('2026-13-01T00:00:00Z');
  CheckBadDate('2025-02-29T00:00:00Z');
  CheckBadDate('2026-01-02T25:00:00Z');
  CheckBadDate('2026-01-02T03:04:05ZX');
  CheckBadDate('2026-01-02T03:04:05.Z');
  CheckBadDate('2026-01-02T03:04:05+2');

  Raised := False;
  try
    ISO8601ToDate('garbage');
  except
    on EConvertError do
      Raised := True;
  end;
  Check(Raised, 'ISO8601ToDate raises EConvertError');
end;

procedure TestEncoding;
var
  Utf8: UTF8String;
begin
  CheckEq(URLEncodeComponent('abcXYZ019-._~'), 'abcXYZ019-._~', 'url unreserved');
  CheckEq(URLEncodeComponent('a b/c?d&e=f+g,h'), 'a%20b%2Fc%3Fd%26e%3Df%2Bg%2Ch', 'url reserved');
  CheckEq(URLEncodeComponent(''), '', 'url empty');
  // UTF-8 source: "é" is C3 A9.
  // Build the bytes by hand: a #$C3#$A9 literal would be treated as two
  // Latin-1 characters and re-encoded at compile time.
  Utf8 := '';
  SetLength(Utf8, 2);
  Utf8[1] := AnsiChar($C3);
  Utf8[2] := AnsiChar($A9);
  CheckEq(URLEncodeComponent(string(Utf8)), '%C3%A9', 'url utf8');

  CheckEq(EncodeBytesBase64(nil), '', 'b64 empty');
  CheckEq(EncodeBytesBase64(BytesOf('f')), 'Zg==', 'b64 f');
  CheckEq(EncodeBytesBase64(BytesOf('fooba')), 'Zm9vYmE=', 'b64 fooba');
  CheckEq(EncodeBytesBase64(BytesOf(#0#1#2#253#254#255)), 'AAEC/f7/', 'b64 binary');

  Check(ParseJSONValue('{"a":') = nil, 'ParseJSONValue invalid -> nil');
  Check(ParseJSONValue('<html>') = nil, 'ParseJSONValue html -> nil');
  Check(ParseJSONValue('') = nil, 'ParseJSONValue empty -> nil');
end;

begin
  TestSha256;
  TestIso8601;
  TestEncoding;
  WriteLn(Format('%d checks, %d failure(s)', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
