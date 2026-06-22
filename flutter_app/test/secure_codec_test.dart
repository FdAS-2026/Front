import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/demo_keys.dart';
import 'package:lora_ble_chat/codec/huffman_codec.dart';
import 'package:lora_ble_chat/codec/rsa_oaep.dart';
import 'package:lora_ble_chat/codec/secure_codec.dart';

void main() {
  final rsa = RsaOaep.fromPem(
    privateKeyPem: DemoKeys.privateKeyPem,
    publicKeyPem: DemoKeys.publicKeyPem,
  );
  final codec = SecureCodec(rsa: rsa);

  test('texto plano queda igual', () {
    final r = codec.decode('Hola'.codeUnits, secure: false);
    expect(r.text, 'Hola');
    expect(r.wasEncrypted, isFalse);
    expect(r.wasCompressed, isFalse);
  });

  test('descifra mensaje base64 cuando el modo seguro esta activo', () {
    final b64 = rsa.encryptToBase64('Secreto del broker');
    final r = codec.decode(b64.codeUnits, secure: true);
    expect(r.text, 'Secreto del broker');
    expect(r.wasEncrypted, isTrue);
  });

  test('con modo seguro apagado no descifra', () {
    final b64 = rsa.encryptToBase64('Secreto');
    final r = codec.decode(b64.codeUnits, secure: false);
    expect(r.wasEncrypted, isFalse);
  });

  test('descomprime payload Huffman', () {
    final compressed = HuffmanCodec().encodeString('mensaje comprimido test');
    final r = codec.decode(compressed, secure: false);
    expect(r.text, 'mensaje comprimido test');
    expect(r.wasCompressed, isTrue);
  });

  test('pipeline completo base64 -> RSA -> Huffman -> texto', () {
    final compressed =
        HuffmanCodec().encodeString('mensaje largo comprimido y cifrado test');
    // Se cifran los bytes crudos comprimidos (igual que en la placa).
    final b64 = base64.encode(rsa.encrypt(compressed));
    final r = codec.decode(b64.codeUnits, secure: true);
    expect(r.text, 'mensaje largo comprimido y cifrado test');
    expect(r.wasEncrypted, isTrue);
    expect(r.wasCompressed, isTrue);
  });
}
