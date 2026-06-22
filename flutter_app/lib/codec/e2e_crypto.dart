import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Par de claves X25519 (32 bytes cada una).
class E2EKeyPair {
  const E2EKeyPair(this.privateKey, this.publicKey);
  final Uint8List privateKey;
  final Uint8List publicKey;
}

/// Cifrado extremo a extremo entre dos placas (dos personas):
///   1. X25519 ECDH entre la privada propia y la publica del contacto.
///   2. HKDF-SHA256 del secreto compartido -> clave AES-256.
///   3. AES-256-GCM. Paquete: nonce(12) || ciphertext || tag(16).
///
/// Cada placa tiene su propio par; las publicas se intercambian al emparejar.
/// Solo el contacto destino (que tiene la privada correspondiente) descifra.
/// Esquema estandar (RFC 7748 + HKDF + GCM) para interoperar con mbedtls en la
/// placa.
class E2ECrypto {
  static final X25519 _x25519 = X25519();
  static final Hkdf _hkdf =
      Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final AesGcm _aes = AesGcm.with256bits();

  // Etiqueta de derivacion (debe coincidir con el firmware).
  static final List<int> _info = 'lora-e2e-v1'.codeUnits;
  static const List<int> _salt = <int>[]; // sin salt (HKDF usa ceros)

  static Future<E2EKeyPair> generateKeyPair() async {
    final kp = await _x25519.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return E2EKeyPair(
      Uint8List.fromList(priv),
      Uint8List.fromList(pub.bytes),
    );
  }

  /// Reconstruye el par desde la semilla (privada de 32 bytes).
  static Future<E2EKeyPair> keyPairFromPrivate(List<int> privateKey) async {
    final kp = await _x25519.newKeyPairFromSeed(privateKey);
    final pub = await kp.extractPublicKey();
    return E2EKeyPair(
      Uint8List.fromList(privateKey),
      Uint8List.fromList(pub.bytes),
    );
  }

  /// Deriva la clave AES-256 compartida con un contacto (ECDH + HKDF).
  static Future<Uint8List> deriveAesKey(
      E2EKeyPair myKeyPair, List<int> theirPublicKey) async {
    final myKp = SimpleKeyPairData(
      myKeyPair.privateKey,
      publicKey: SimplePublicKey(myKeyPair.publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKp,
      remotePublicKey:
          SimplePublicKey(theirPublicKey, type: KeyPairType.x25519),
    );
    final aesKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: _salt,
      info: _info,
    );
    return Uint8List.fromList(await aesKey.extractBytes());
  }

  /// Cifra con la clave AES-256. Devuelve nonce(12) || ciphertext || tag(16).
  static Future<Uint8List> encrypt(Uint8List aesKey, List<int> plaintext) async {
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(aesKey),
    );
    return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Descifra un paquete nonce||ct||tag. Devuelve null si falla la autenticacion.
  static Future<Uint8List?> decrypt(Uint8List aesKey, List<int> packet) async {
    if (packet.length < 12 + 16) return null;
    final nonce = packet.sublist(0, 12);
    final mac = packet.sublist(packet.length - 16);
    final ct = packet.sublist(12, packet.length - 16);
    try {
      final clear = await _aes.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(aesKey),
      );
      return Uint8List.fromList(clear);
    } catch (_) {
      return null; // tag invalido / clave incorrecta
    }
  }
}
