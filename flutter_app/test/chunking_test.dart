import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/chunking.dart';

void main() {
  group('splitUtf8 byte-aware', () {
    test('texto ASCII de longitud mayor a maxBytes: produce ceil(len/maxBytes) chunks', () {
      // "0123456789" = 10 bytes ASCII; maxBytes=4 -> 3 chunks
      const texto = '0123456789';
      final chunks = Chunking.splitUtf8(texto, 4);
      expect(chunks.length, 3);
      expect(chunks[0], utf8.encode('0123'));
      expect(chunks[1], utf8.encode('4567'));
      expect(chunks[2], utf8.encode('89'));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(4));
      }
    });

    test('acento de 2 bytes UTF-8: el corte no cae a mitad del codepoint', () {
      // 'café' = c(1)+a(1)+f(1)+é(0xC3 0xA9 = 2 bytes) = 5 bytes
      // maxBytes=4 -> end=4 apunta al byte 0xA9 (continuation); retrocede a 3
      // chunk[0]='caf' (3 bytes), chunk[1]='é' (2 bytes)
      const texto = 'café';
      final todosBytesEsperados = utf8.encode(texto);
      expect(todosBytesEsperados.length, 5); // sanidad
      final chunks = Chunking.splitUtf8(texto, 4);
      // Ningun chunk debe decodificar a U+FFFD (corte a mitad)
      for (final c in chunks) {
        expect(utf8.decode(c).contains('�'), isFalse,
            reason: 'el chunk $c produce reemplazo UTF-8: codepoint partido');
      }
      // Round-trip: la concatenacion de los decodificados es el texto original
      expect(chunks.map(utf8.decode).join(), texto);
    });

    test('emoji de 4 bytes: ningun chunk parte el surrogate', () {
      // '😀' = 0xF0 0x9F 0x98 0x80 = 4 bytes
      // '😀😀' = 8 bytes; maxBytes=5 -> end=5 apunta a 0x9F (continuation)
      // retrocede a 4 (0xF0, leading byte): chunk[0]='😀', chunk[1]='😀'
      const texto = '😀😀';
      final chunks = Chunking.splitUtf8(texto, 5);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(5));
        expect(utf8.decode(c).contains('�'), isFalse,
            reason: 'chunk partido produce U+FFFD');
      }
      expect(chunks.map(utf8.decode).join(), texto);
    });

    test('round-trip: split + decode reconstruye el texto original', () {
      // Texto con acentos latinos y emoji para maxima cobertura de codepoints
      const texto = 'Hola, ñoño 😀 áéíóú';
      final chunks = Chunking.splitUtf8(texto, 10);
      expect(chunks, isNotEmpty);
      final reunido = chunks.map((c) => utf8.decode(c)).join();
      expect(reunido, texto);
    });

    // Regresion CR-02: maxBytes menor que el codepoint completo no debe congelar
    // ni lanzar (guard de avance forzado de 1 byte).
    test('splitUtf8 con maxBytes < tamano de codepoint no congela ni lanza', () {
      // '😀' = 4 bytes; maxBytes=3 -> sin guard retrocederia a start cada vez
      expect(() => Chunking.splitUtf8('😀', 3), returnsNormally);
      final chunks = Chunking.splitUtf8('😀', 3);
      expect(chunks, isNotEmpty); // al menos un chunk producido
    });
  });

  group('header de parte', () {
    test('buildPartHeader produce bytes con STX/ETX y grp:i:n en ASCII', () {
      final header = Chunking.buildPartHeader(42, 1, 3);
      expect(header.first, Chunking.kPartStart); // 0x01 STX
      expect(header.last, Chunking.kPartEnd);    // 0x02 ETX
      final inner = utf8.decode(header.sublist(1, header.length - 1));
      expect(inner, '42:1:3');
    });

    test('parsePartHeader hace round-trip exacto de buildChunkPayload', () {
      final chunkBytes = utf8.encode('texto de prueba con acento á');
      final payload = Chunking.buildChunkPayload(42, 1, 3, chunkBytes);
      final result = Chunking.parsePartHeader(payload);
      expect(result, isNotNull);
      expect(result!.grp, 42);
      expect(result.i, 1);
      expect(result.n, 3);
      expect(result.textBytes, chunkBytes);
    });

    test('parsePartHeader con payload sin 0x01 inicial devuelve null', () {
      final payload = utf8.encode('texto normal sin header');
      expect(Chunking.parsePartHeader(payload), isNull);
    });

    test('parsePartHeader con header sin 0x02 (ETX faltante) devuelve null', () {
      // STX presente pero sin ETX
      final payload = [Chunking.kPartStart, ...utf8.encode('42:1:3')];
      expect(Chunking.parsePartHeader(payload), isNull);
    });

    test('parsePartHeader con campos no numericos devuelve null', () {
      final payload = [
        Chunking.kPartStart,
        ...utf8.encode('abc:1:3'), // 'abc' no es entero
        Chunking.kPartEnd,
        ...utf8.encode('texto'),
      ];
      expect(Chunking.parsePartHeader(payload), isNull);
    });

    // Regresion CR-01: n invalido o i fuera de rango deben devolver null.
    test('parsePartHeader con n=0 devuelve null', () {
      final payload = [
        Chunking.kPartStart,
        ...utf8.encode('1:0:0'), // n=0 invalido
        Chunking.kPartEnd,
        ...utf8.encode('x'),
      ];
      expect(Chunking.parsePartHeader(payload), isNull);
    });

    test('parsePartHeader con n=-1 devuelve null', () {
      final payload = [
        Chunking.kPartStart,
        ...utf8.encode('1:0:-1'), // n=-1 invalido
        Chunking.kPartEnd,
        ...utf8.encode('x'),
      ];
      expect(Chunking.parsePartHeader(payload), isNull);
    });

    test('parsePartHeader con i >= n devuelve null', () {
      final payload = [
        Chunking.kPartStart,
        ...utf8.encode('1:3:3'), // i=3 >= n=3 invalido
        Chunking.kPartEnd,
        ...utf8.encode('x'),
      ];
      expect(Chunking.parsePartHeader(payload), isNull);
    });
  });

  group('buildChunkPayload', () {
    test('n=1: devuelve exactamente los bytes del chunk (sin header)', () {
      final chunkBytes = utf8.encode('mensaje de una sola parte');
      final payload = Chunking.buildChunkPayload(0, 0, 1, chunkBytes);
      expect(payload, chunkBytes);
    });

    test('n>1: header antepuesto y los ultimos bytes son el chunk', () {
      final chunkBytes = utf8.encode('parte de mensaje multi-parte');
      final payload = Chunking.buildChunkPayload(7, 0, 2, chunkBytes);
      // Debe empezar con STX
      expect(payload.first, Chunking.kPartStart);
      // Los ultimos bytes deben ser exactamente chunkBytes
      expect(payload.sublist(payload.length - chunkBytes.length), chunkBytes);
      // Longitud total = header + chunkBytes
      final longHeader = Chunking.buildPartHeader(7, 0, 2).length;
      expect(payload.length, longHeader + chunkBytes.length);
    });
  });

  group('reassemble (PartGroup)', () {
    test('agregar 3 partes en orden [2,0,1]: isComplete y assemble == original', () {
      // Texto con acentos y emoji para verificar round-trip UTF-8 completo
      final bytes0 = utf8.encode('Hola');
      final bytes1 = utf8.encode(', ñoño');
      final bytes2 = utf8.encode(' 😀');
      const textoOriginal = 'Hola, ñoño 😀';

      final group = PartGroup(3);
      group.addPart(2, bytes2); // primer insert: parte 2
      expect(group.isComplete, isFalse);
      group.addPart(0, bytes0); // segundo insert: parte 0
      expect(group.isComplete, isFalse);
      group.addPart(1, bytes1); // tercero: parte 1 -> completo
      expect(group.isComplete, isTrue);
      expect(group.assemble(), textoOriginal);
    });

    test('faltando 1 parte: isComplete es false', () {
      final group = PartGroup(3);
      group.addPart(0, utf8.encode('primera '));
      group.addPart(2, utf8.encode(' tercera'));
      // parte 1 nunca agregada
      expect(group.isComplete, isFalse);
    });

    test('re-agregar una parte ya presente no incrementa received ni corrompe', () {
      final group = PartGroup(2);
      group.addPart(0, utf8.encode('primera'));
      final receivedAntes = group.received;
      // Duplicado con contenido distinto; debe ignorarse
      group.addPart(0, utf8.encode('DUPLICADO'));
      expect(group.received, receivedAntes,
          reason: 'received no debe incrementar con parte duplicada');
      group.addPart(1, utf8.encode(' segunda'));
      expect(group.isComplete, isTrue);
      // El texto debe ser el original, no el duplicado
      expect(group.assemble(), 'primera segunda');
    });
  });
}
