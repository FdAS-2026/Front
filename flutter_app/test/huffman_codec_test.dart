import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/huffman_codec.dart';

void main() {
  final codec = HuffmanCodec();

  group('HuffmanCodec roundtrip', () {
    test('texto simple', () {
      const original = 'Hola mundo LoRa';
      expect(codec.decodeToString(codec.encodeString(original)), original);
    });

    test('vacio', () {
      expect(codec.decodeToString(codec.encodeString('')), '');
    });

    test('simbolo unico repetido', () {
      const original = 'aaaaaaaa';
      expect(codec.decodeToString(codec.encodeString(original)), original);
    });

    test('un solo caracter', () {
      expect(codec.decodeToString(codec.encodeString('x')), 'x');
    });

    test('bytes UTF-8 con acentos', () {
      const original = 'áé repeticion repeticion repeticion';
      expect(codec.decodeToString(codec.encodeString(original)), original);
    });

    test('comprime texto repetitivo', () {
      final original = 'el mensaje se repite ' * 30;
      final encoded = codec.encodeString(original);
      expect(encoded.length < utf8.encode(original).length, isTrue);
    });

    test('datos invalidos retornan vacio', () {
      expect(codec.decode(Uint8List.fromList([0x05, 0x00, 0x00])), isEmpty);
    });
  });

  group('Interoperabilidad con el firmware C++', () {
    test('decodifica el buffer generado por la placa', () {
      // Vector "golden" producido por HuffmanCodec.cpp para "Hola mundo LoRa".
      const hex =
          '0f0000000b00200200000048010000004c010000005201000000610200000064'
          '010000006c010000006d010000006e010000006f030000007501000000831adf'
          'eb1494c0';
      final bytes = _hexToBytes(hex);
      expect(codec.decodeToString(bytes), 'Hola mundo LoRa');
    });
  });
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
