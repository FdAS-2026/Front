import 'dart:convert';

import 'huffman_codec.dart';
import 'rsa_cipher.dart';

/// Resultado de decodificar un mensaje entrante.
class DecodedMessage {
  const DecodedMessage(this.text, this.wasEncrypted, this.wasCompressed);
  final String text;
  final bool wasEncrypted;
  final bool wasCompressed;
}

/// Acopla la funcionalidad del firmware (Huffman + RSA) en la recepcion de la
/// app: dado el payload crudo que llega por BLE, intenta automaticamente
/// descifrar (si el modo seguro esta activo y el texto es hex) y luego
/// descomprimir (si es un buffer Huffman valido), cayendo a texto plano.
class SecureCodec {
  final HuffmanCodec _huffman = HuffmanCodec();

  DecodedMessage decode(
    List<int> raw, {
    required bool secure,
    int? privD,
    int? privN,
  }) {
    var bytes = raw;
    var encrypted = false;
    var compressed = false;

    // Paso 1: descifrado RSA de un payload hexadecimal.
    if (secure && privD != null && privN != null) {
      final asText = String.fromCharCodes(raw);
      if (_isHex(asText)) {
        final decrypted =
            RsaCipher.decrypt(RsaCipher.hexToBytes(asText), privD, privN);
        if (decrypted.isNotEmpty) {
          bytes = decrypted;
          encrypted = true;
        }
      }
    }

    // Paso 2: descompresion Huffman si el buffer es valido.
    final inflated = _huffman.decode(bytes);
    if (inflated.isNotEmpty) {
      bytes = inflated;
      compressed = true;
    }

    return DecodedMessage(
      utf8.decode(bytes, allowMalformed: true),
      encrypted,
      compressed,
    );
  }

  bool _isHex(String s) {
    if (s.isEmpty || s.length.isOdd || s.length < 8) return false;
    for (final c in s.codeUnits) {
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLower = c >= 0x61 && c <= 0x66;
      final isUpper = c >= 0x41 && c <= 0x46;
      if (!isDigit && !isLower && !isUpper) return false;
    }
    return true;
  }
}
