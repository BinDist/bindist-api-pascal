unit BinDist.Sha256;

{ Self-contained SHA-256 (FIPS 180-4) for Free Pascal 3.2.2, which ships no
  SHA-2 unit. THashSHA2 mirrors the subset of Delphi's System.Hash.THashSHA2
  that the BinDist units use (Create / Update / HashAsString), so the call
  sites in BinDist.ClientV1 and BinDist.AdminV1 stay identical to Delphi. }

{$mode delphi}{$H+}
{$Q-}{$R-}

interface

uses
  SysUtils;

type
  TSHA256Digest = array[0..31] of Byte;

  THashSHA2 = record
  private
    FState: array[0..7] of Cardinal;
    FBuffer: array[0..63] of Byte;
    FBufferLen: Integer;
    FTotalLen: QWord;
    procedure Compress(const Block: PByte);
  public
    class function Create: THashSHA2; static;
    procedure Reset;
    procedure Update(const AData; ALength: NativeUInt); overload;
    procedure Update(const AData: TBytes; ALength: NativeUInt); overload;
    procedure Update(const AData: TBytes); overload;
    function HashAsBytes: TSHA256Digest;
    /// Lowercase hex digest. Finalises a copy, so the state is not consumed.
    function HashAsString: string;
    class function GetHashString(const AData: TBytes): string; static;
  end;

function SHA256DigestToHex(const Digest: TSHA256Digest): string;

implementation

type
  TPadBlock = array[0..71] of Byte;

const
  K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function SHA256DigestToHex(const Digest: TSHA256Digest): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, 64);
  for I := 0 to 31 do
  begin
    Result[I * 2 + 1] := HexChars[Digest[I] shr 4];
    Result[I * 2 + 2] := HexChars[Digest[I] and $0F];
  end;
end;

{ THashSHA2 }

class function THashSHA2.Create: THashSHA2;
begin
  Result := Default(THashSHA2);
  Result.Reset;
end;

procedure THashSHA2.Reset;
begin
  FState[0] := $6a09e667;
  FState[1] := $bb67ae85;
  FState[2] := $3c6ef372;
  FState[3] := $a54ff53a;
  FState[4] := $510e527f;
  FState[5] := $9b05688c;
  FState[6] := $1f83d9ab;
  FState[7] := $5be0cd19;
  FBufferLen := 0;
  FTotalLen := 0;
end;

procedure THashSHA2.Compress(const Block: PByte);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1: Cardinal;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (Cardinal(Block[I * 4]) shl 24) or (Cardinal(Block[I * 4 + 1]) shl 16) or
            (Cardinal(Block[I * 4 + 2]) shl 8) or Cardinal(Block[I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := RorDWord(W[I - 15], 7) xor RorDWord(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := RorDWord(W[I - 2], 17) xor RorDWord(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;

  A := FState[0]; B := FState[1]; C := FState[2]; D := FState[3];
  E := FState[4]; F := FState[5]; G := FState[6]; H := FState[7];

  for I := 0 to 63 do
  begin
    S1 := RorDWord(E, 6) xor RorDWord(E, 11) xor RorDWord(E, 25);
    T1 := H + S1 + ((E and F) xor ((not E) and G)) + K[I] + W[I];
    S0 := RorDWord(A, 2) xor RorDWord(A, 13) xor RorDWord(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    H := G; G := F; F := E; E := D + T1;
    D := C; C := B; B := A; A := T1 + T2;
  end;

  Inc(FState[0], A); Inc(FState[1], B); Inc(FState[2], C); Inc(FState[3], D);
  Inc(FState[4], E); Inc(FState[5], F); Inc(FState[6], G); Inc(FState[7], H);
end;

procedure THashSHA2.Update(const AData; ALength: NativeUInt);
var
  P: PByte;
  N: NativeUInt;
begin
  if ALength = 0 then
    Exit;
  P := @AData;
  Inc(FTotalLen, ALength);

  if FBufferLen > 0 then
  begin
    N := 64 - FBufferLen;
    if N > ALength then
      N := ALength;
    Move(P^, FBuffer[FBufferLen], N);
    Inc(FBufferLen, N);
    Inc(P, N);
    Dec(ALength, N);
    if FBufferLen = 64 then
    begin
      Compress(@FBuffer[0]);
      FBufferLen := 0;
    end;
  end;

  while ALength >= 64 do
  begin
    Compress(P);
    Inc(P, 64);
    Dec(ALength, 64);
  end;

  if ALength > 0 then
  begin
    Move(P^, FBuffer[0], ALength);
    FBufferLen := ALength;
  end;
end;

procedure THashSHA2.Update(const AData: TBytes; ALength: NativeUInt);
begin
  if ALength > NativeUInt(Length(AData)) then
    ALength := Length(AData);
  if ALength > 0 then
    Update(AData[0], ALength);
end;

procedure THashSHA2.Update(const AData: TBytes);
begin
  Update(AData, Length(AData));
end;

function THashSHA2.HashAsBytes: TSHA256Digest;
var
  Ctx: THashSHA2;
  BitLen: QWord;
  Pad: TPadBlock;
  PadLen, I: Integer;
begin
  Ctx := Self;
  BitLen := Ctx.FTotalLen * 8;

  Pad := Default(TPadBlock);
  Pad[0] := $80;
  if Ctx.FBufferLen < 56 then
    PadLen := 56 - Ctx.FBufferLen
  else
    PadLen := 120 - Ctx.FBufferLen;
  for I := 0 to 7 do
    Pad[PadLen + I] := Byte(BitLen shr (56 - I * 8));
  Ctx.Update(Pad[0], PadLen + 8);

  for I := 0 to 7 do
  begin
    Result[I * 4] := Byte(Ctx.FState[I] shr 24);
    Result[I * 4 + 1] := Byte(Ctx.FState[I] shr 16);
    Result[I * 4 + 2] := Byte(Ctx.FState[I] shr 8);
    Result[I * 4 + 3] := Byte(Ctx.FState[I]);
  end;
end;

function THashSHA2.HashAsString: string;
begin
  Result := SHA256DigestToHex(HashAsBytes);
end;

class function THashSHA2.GetHashString(const AData: TBytes): string;
var
  Hash: THashSHA2;
begin
  Hash := THashSHA2.Create;
  Hash.Update(AData);
  Result := Hash.HashAsString;
end;

end.
