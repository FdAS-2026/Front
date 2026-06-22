import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/huffman_codec.dart';
import 'package:lora_ble_chat/codec/rsa_cipher.dart';
import 'package:lora_ble_chat/codec/secure_codec.dart';

void main() {
  const e = 65537;
  const n = 3601800221;
  const d = 1778720129;

  final codec = SecureCodec();

  test('texto plano queda igual', () {
    final r = codec.decode('Hola'.codeUnits, secure: false);
    expect(r.text, 'Hola');
    expect(r.wasEncrypted, isFalse);
    expect(r.wasCompressed, isFalse);
  });

  test('descifra mensaje hex cuando el modo seguro esta activo', () {
    final cipher = RsaCipher.encryptString('Secreto', e, n);
    final hex = _toHex(cipher);
    final r = codec.decode(hex.codeUnits, secure: true, privD: d, privN: n);
    expect(r.text, 'Secreto');
    expect(r.wasEncrypted, isTrue);
  });

  test('descomprime payload Huffman', () {
    final compressed = HuffmanCodec().encodeString('mensaje comprimido test');
    final r = codec.decode(compressed, secure: false);
    expect(r.text, 'mensaje comprimido test');
    expect(r.wasCompressed, isTrue);
  });

  test('pipeline completo hex -> RSA -> Huffman -> texto', () {
    final compressed =
        HuffmanCodec().encodeString('mensaje largo comprimido y cifrado test');
    final cipher = RsaCipher.encrypt(compressed, e, n);
    final hex = _toHex(cipher);
    final r = codec.decode(hex.codeUnits, secure: true, privD: d, privN: n);
    expect(r.text, 'mensaje largo comprimido y cifrado test');
    expect(r.wasEncrypted, isTrue);
    expect(r.wasCompressed, isTrue);
  });
}

String _toHex(List<int> bytes) {
  const h = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(h[(b >> 4) & 0xF]);
    sb.write(h[b & 0xF]);
  }
  return sb.toString();
}
