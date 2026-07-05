// board_events_test.dart — parsing puro de eventos de la placa (QUAL-02).
// Cubre en especial SENT con cid, la pieza del fix de WR-02.

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/board_events.dart';

void main() {
  group('BoardEvent.parse', () {
    test('separa tag y rest en el primer :', () {
      final e = BoardEvent.parse('MSG:1A2B:hola:mundo');
      expect(e.tag, 'MSG');
      expect(e.rest, '1A2B:hola:mundo');
    });
    test('sin : el rest es vacio', () {
      final e = BoardEvent.parse('CONTACTS_END');
      expect(e.tag, 'CONTACTS_END');
      expect(e.rest, '');
    });
  });

  group('SentEvent.parse', () {
    test('con cid', () {
      final s = SentEvent.parse('00a1:1b2c:42')!;
      expect(s.msgId, '00A1');
      expect(s.dst, '1B2C');
      expect(s.cid, 42);
    });
    test('sin cid (formato viejo) -> cid null', () {
      final s = SentEvent.parse('00a1:1b2c')!;
      expect(s.msgId, '00A1');
      expect(s.dst, '1B2C');
      expect(s.cid, isNull);
    });
    test('cid no numerico -> null', () {
      final s = SentEvent.parse('00a1:1b2c:xx')!;
      expect(s.cid, isNull);
    });
    test('rest incompleto -> null', () {
      expect(SentEvent.parse('00a1'), isNull);
      expect(SentEvent.parse(':1b2c'), isNull);
    });

    test('WR-02: dos cids se resuelven a partes distintas sin importar el orden',
        () {
      // Simula el mapa cid->(burbuja,parte) del widget con una estructura simple.
      final targets = <int, List<int>>{}; // cid -> [bubbleId, part]
      targets[10] = [0, 0]; // msg A, parte 0
      targets[11] = [0, 1]; // msg A, parte 1
      targets[12] = [1, 0]; // msg B, parte 0

      // Los SENT llegan DESORDENADOS (12 antes que 11).
      final incoming = ['aa:99:10', 'cc:99:12', 'bb:99:11'];
      final assigned = <String, String>{}; // "bubble:part" -> msgId
      for (final raw in incoming) {
        final s = SentEvent.parse(raw)!;
        final t = targets[s.cid]!;
        assigned['${t[0]}:${t[1]}'] = s.msgId;
      }
      // Cada parte recibio SU msgId, no el del vecino.
      expect(assigned['0:0'], 'AA'); // A parte0 <- cid10
      expect(assigned['0:1'], 'BB'); // A parte1 <- cid11 (llego ultimo)
      expect(assigned['1:0'], 'CC'); // B parte0 <- cid12 (llego 2do)
    });
  });

  group('AckEvent.parse', () {
    test('lora / broker', () {
      expect(AckEvent.parse('00a1:lora')!.viaBroker, false);
      expect(AckEvent.parse('00a1:broker')!.viaBroker, true);
      expect(AckEvent.parse('00a1:broker')!.msgId, '00A1');
    });
    test('incompleto -> null', () {
      expect(AckEvent.parse('00a1'), isNull);
    });
  });

  group('ContactEntry.parse', () {
    test('id=nombre', () {
      final c = ContactEntry.parse('1a2b=Ana')!;
      expect(c.id, '1a2b');
      expect(c.name, 'Ana');
    });
    test('nombre con = extra', () {
      final c = ContactEntry.parse('1a2b=Ana=x')!;
      expect(c.name, 'Ana=x');
    });
    test('sin = -> null', () {
      expect(ContactEntry.parse('1a2b'), isNull);
    });
  });
}
