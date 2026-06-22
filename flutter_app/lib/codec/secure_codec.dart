import 'dart:convert';

import 'huffman_codec.dart';
import 'rsa_oaep.dart';

/// Resultado de decodificar un mensaje entrante.
class DecodedMessage {
  const DecodedMessage(this.text, this.wasEncrypted, this.wasCompressed);
  final String text;
  final bool wasEncrypted;
  final bool wasCompressed;
}

/// Acopla la funcionalidad del firmware (RSA-2048 OAEP + Huffman) en la
/// recepcion de la app: dado el payload crudo que llega, intenta automaticamente
/// descifrar (si el modo seguro esta activo y el texto es base64 valido) y luego
/// descomprimir (si es un buffer Huffman valido), cayendo a texto plano.
class SecureCodec {
  SecureCodec({RsaOaep? rsa}) : _rsa = rsa;

  final HuffmanCodec _huffman = HuffmanCodec();
  final RsaOaep? _rsa;

  DecodedMessage decode(List<int> raw, {required bool secure}) {
    var bytes = raw;
    var encrypted = false;
    var compressed = false;

    // Paso 1: descifrado RSA-OAEP de un payload base64.
    final rsa = _rsa;
    if (secure && rsa != null && rsa.canDecrypt) {
      final asText = String.fromCharCodes(raw).trim();
      if (_looksBase64(asText)) {
        final decrypted = rsa.decryptFromBase64(asText);
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

  // Un bloque RSA-2048 en base64 ocupa 344 caracteres; exigimos un minimo
  // razonable y solo el alfabeto base64 estandar.
  bool _looksBase64(String s) {
    if (s.length < 44 || s.length % 4 != 0) return false;
    for (final c in s.codeUnits) {
      final isUpper = c >= 0x41 && c <= 0x5A;
      final isLower = c >= 0x61 && c <= 0x7A;
      final isDigit = c >= 0x30 && c <= 0x39;
      final isSym = c == 0x2B || c == 0x2F || c == 0x3D; // + / =
      if (!isUpper && !isLower && !isDigit && !isSym) return false;
    }
    return true;
  }
}
