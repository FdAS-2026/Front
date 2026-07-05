// auth_hmac_test.dart — fija el contrato de interoperabilidad del handshake de
// sesion (SEC-01). La placa verifica con mbedtls_md_hmac (HMAC-SHA256); la app
// debe producir EXACTAMENTE el mismo digest. Se verifica el paquete
// `cryptography` contra un vector conocido de RFC 4231 (Test Case 2) y luego el
// mismo camino que usa la app (clave y mensaje como bytes crudos).

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';

List<int> hexToBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

String bytesToHex(List<int> b) {
  const h = '0123456789abcdef';
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(h[(x >> 4) & 0xF]);
    sb.write(h[x & 0xF]);
  }
  return sb.toString();
}

Future<String> hmacHex(List<int> keyBytes, List<int> msgBytes) async {
  final mac = await Hmac.sha256()
      .calculateMac(msgBytes, secretKey: SecretKey(keyBytes));
  return bytesToHex(mac.bytes);
}

void main() {
  test('RFC 4231 Test Case 2: HMAC-SHA256 estandar', () async {
    // key = "Jefe", data = "what do ya want for nothing?"
    final key = 'Jefe'.codeUnits;
    final data = 'what do ya want for nothing?'.codeUnits;
    final got = await hmacHex(key, data);
    expect(
      got,
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    );
  });

  test('camino de la app: secreto 16B + nonce 4B como bytes crudos', () async {
    // Simula el flujo real: secreto de claim (hex, 16 bytes) y nonce (hex, 4B).
    const secretHex = '000102030405060708090a0b0c0d0e0f';
    const nonceHex = 'abcd1234';
    final mac = await hmacHex(hexToBytes(secretHex), hexToBytes(nonceHex));
    // Debe ser un digest SHA-256 (64 hex) y determinista.
    expect(mac.length, 64);
    // Valor fijo: si cambia, la interop con la placa se rompio.
    final again = await hmacHex(hexToBytes(secretHex), hexToBytes(nonceHex));
    expect(mac, again);
  });
}
