import 'dart:convert';
import 'dart:typed_data';

/// Par de claves RSA (de demostracion, compatible con el firmware).
class RsaKeyPair {
  const RsaKeyPair(this.e, this.d, this.n, this.valid);
  final int e;
  final int d;
  final int n;
  final bool valid;
}

/// Cifrado RSA "de libro de texto" compatible byte a byte con `RsaCipher.cpp`.
///
/// Cada byte se cifra de forma independiente y se serializa como un bloque de
/// 4 bytes (uint32 little-endian). La app guarda la clave PRIVADA (d, n) para
/// descifrar lo que la placa publica en el broker cifrado con la clave publica.
///
/// Implementacion didactica (no apta para produccion). Usa BigInt internamente
/// para evitar desbordes en la exponenciacion modular.
class RsaCipher {
  static RsaKeyPair generate(int p, int q, int e) {
    final n = p * q;
    if (n <= 255) return RsaKeyPair(e, 0, 0, false);
    final phi = (p - 1) * (q - 1);
    if (e < 2 || e >= phi) return RsaKeyPair(e, 0, 0, false);
    if (_gcd(e, phi) != 1) return RsaKeyPair(e, 0, 0, false);
    final d = _modInverse(e, phi);
    if (d == 0) return RsaKeyPair(e, 0, 0, false);
    return RsaKeyPair(e, d, n, true);
  }

  static Uint8List encryptString(String plain, int e, int n) =>
      encrypt(utf8.encode(plain), e, n);

  static Uint8List encrypt(List<int> plain, int e, int n) {
    final out = <int>[];
    if (plain.isEmpty || n <= 255) return Uint8List.fromList(out);
    final bigE = BigInt.from(e);
    final bigN = BigInt.from(n);
    for (final c in plain) {
      final cipher = BigInt.from(c & 0xFF).modPow(bigE, bigN).toInt();
      _putU32(out, cipher);
    }
    return Uint8List.fromList(out);
  }

  static String decryptToString(List<int> cipher, int d, int n) =>
      utf8.decode(decrypt(cipher, d, n), allowMalformed: true);

  static List<int> decrypt(List<int> cipher, int d, int n) {
    final out = <int>[];
    if (cipher.isEmpty || cipher.length % 4 != 0 || n <= 255) return out;
    final bigD = BigInt.from(d);
    final bigN = BigInt.from(n);
    for (var i = 0; i + 4 <= cipher.length; i += 4) {
      final block = cipher[i] |
          (cipher[i + 1] << 8) |
          (cipher[i + 2] << 16) |
          (cipher[i + 3] << 24);
      final m = BigInt.from(block).modPow(bigD, bigN).toInt();
      out.add(m & 0xFF);
    }
    return out;
  }

  static Uint8List hexToBytes(String hex) {
    final clean = hex.trim();
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a;
  }

  static int _modInverse(int e, int m) {
    var t = 0, newt = 1;
    var r = m, newr = e;
    while (newr != 0) {
      final q = r ~/ newr;
      var tmp = t - q * newt;
      t = newt;
      newt = tmp;
      tmp = r - q * newr;
      r = newr;
      newr = tmp;
    }
    if (r > 1) return 0;
    if (t < 0) t += m;
    return t;
  }

  static void _putU32(List<int> out, int v) {
    out.add(v & 0xFF);
    out.add((v >> 8) & 0xFF);
    out.add((v >> 16) & 0xFF);
    out.add((v >> 24) & 0xFF);
  }
}
