import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart';

/// Cifrado RSA-2048 con padding OAEP (SHA-256), compatible con el firmware
/// (mbedtls) y con OpenSSL. La app usa la CLAVE PRIVADA para descifrar lo que
/// la placa publica en el broker cifrado con la clave publica.
class RsaOaep {
  RsaOaep._(this._privateKey, this._publicKey);

  final RSAPrivateKey? _privateKey;
  final RSAPublicKey? _publicKey;

  /// Construye desde PEM. Cualquiera de las dos claves puede ser null.
  factory RsaOaep.fromPem({String? privateKeyPem, String? publicKeyPem}) {
    final priv = (privateKeyPem != null && privateKeyPem.trim().isNotEmpty)
        ? CryptoUtils.rsaPrivateKeyFromPem(privateKeyPem)
        : null;
    final pub = (publicKeyPem != null && publicKeyPem.trim().isNotEmpty)
        ? CryptoUtils.rsaPublicKeyFromPem(publicKeyPem)
        : null;
    return RsaOaep._(priv, pub);
  }

  bool get canDecrypt => _privateKey != null;
  bool get canEncrypt => _publicKey != null;

  OAEPEncoding _oaep(bool forEncryption, RSAAsymmetricKey key) {
    final engine = OAEPEncoding.withSHA256(RSAEngine());
    engine.init(
      forEncryption,
      forEncryption
          ? PublicKeyParameter<RSAPublicKey>(key as RSAPublicKey)
          : PrivateKeyParameter<RSAPrivateKey>(key as RSAPrivateKey),
    );
    return engine;
  }

  /// Cifra (principalmente para pruebas; en produccion cifra la placa).
  Uint8List encrypt(List<int> data) {
    final key = _publicKey;
    if (key == null) throw StateError('Sin clave publica');
    return _process(_oaep(true, key), Uint8List.fromList(data));
  }

  String encryptToBase64(String text) => base64.encode(encrypt(utf8.encode(text)));

  /// Descifra los bytes del bloque RSA. Devuelve vacio si falla.
  Uint8List decrypt(List<int> cipher) {
    final key = _privateKey;
    if (key == null) return Uint8List(0);
    try {
      return _process(_oaep(false, key), Uint8List.fromList(cipher));
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Descifra un mensaje en base64. Vacio si no es valido o falla.
  Uint8List decryptFromBase64(String b64) {
    try {
      return decrypt(base64.decode(b64));
    } catch (_) {
      return Uint8List(0);
    }
  }

  Uint8List _process(AsymmetricBlockCipher cipher, Uint8List input) {
    final blockSize = cipher.inputBlockSize;
    final out = BytesBuilder();
    var offset = 0;
    while (offset < input.length) {
      final len = (offset + blockSize < input.length)
          ? blockSize
          : input.length - offset;
      out.add(cipher.process(input.sublist(offset, offset + len)));
      offset += len;
    }
    return out.toBytes();
  }
}
