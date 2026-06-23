import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/main.dart';

void main() {
  group('ChatMessage — compatibilidad de 1 parte', () {
    test('sin partIds tiene exactamente 1 parte y msgId apunta al primer slot', () {
      final m = ChatMessage('hola', true, false, msgId: 'AA');
      expect(m.partMsgIds.length, 1);
      expect(m.partMsgIds.first, 'AA');
      expect(m.msgId, 'AA');
    });

    test('sin msgId ni partIds el unico slot es null', () {
      final m = ChatMessage('texto', true, false);
      expect(m.partMsgIds.length, 1);
      expect(m.partMsgIds.first, isNull);
      expect(m.msgId, isNull);
    });

    test('setter msgId modifica el primer slot de partMsgIds', () {
      final m = ChatMessage('texto', true, false);
      m.msgId = 'BB';
      expect(m.partMsgIds[0], 'BB');
      expect(m.msgId, 'BB');
    });

    test('partStatuses y partMediums tienen longitud 1 con valores iniciales', () {
      final m = ChatMessage('texto', true, false);
      expect(m.partStatuses.length, 1);
      expect(m.partMediums.length, 1);
      expect(m.partStatuses[0], MsgStatus.sending);
      expect(m.partMediums[0], MsgMedium.none);
    });
  });

  group('ChatMessage — multi-parte (2 partes)', () {
    test('partIds define la cantidad de partes y todas arrancan en sending/none', () {
      final m = ChatMessage('texto largo', true, false,
          partIds: [null, null]);
      expect(m.partMsgIds.length, 2);
      expect(m.partStatuses.length, 2);
      expect(m.partMediums.length, 2);
      expect(m.partStatuses.every((s) => s == MsgStatus.sending), isTrue);
      expect(m.partMediums.every((md) => md == MsgMedium.none), isTrue);
    });
  });

  group('ChatMessage — assignNextMsgId', () {
    test('asigna al primer slot null y devuelve true', () {
      final m = ChatMessage('texto', true, false, partIds: [null, null]);
      expect(m.assignNextMsgId('ID1'), isTrue);
      expect(m.partMsgIds[0], 'ID1');
      expect(m.partMsgIds[1], isNull);
    });

    test('asigna al segundo slot si el primero ya tiene id', () {
      final m = ChatMessage('texto', true, false, partIds: ['ID1', null]);
      expect(m.assignNextMsgId('ID2'), isTrue);
      expect(m.partMsgIds[0], 'ID1');
      expect(m.partMsgIds[1], 'ID2');
    });

    test('devuelve false si todos los slots tienen id', () {
      final m = ChatMessage('texto', true, false, partIds: ['ID1', 'ID2']);
      expect(m.assignNextMsgId('ID3'), isFalse);
    });
  });

  group('ChatMessage — hasMsgId', () {
    test('devuelve true si alguna parte tiene ese id', () {
      final m = ChatMessage('texto', true, false, partIds: ['AA', 'BB']);
      expect(m.hasMsgId('AA'), isTrue);
      expect(m.hasMsgId('BB'), isTrue);
    });

    test('devuelve false si ningun slot tiene ese id', () {
      final m = ChatMessage('texto', true, false, partIds: ['AA', null]);
      expect(m.hasMsgId('CC'), isFalse);
    });

    test('devuelve false ante null en todos los slots', () {
      final m = ChatMessage('texto', true, false, partIds: [null, null]);
      expect(m.hasMsgId('XX'), isFalse);
    });
  });

  group('ChatMessage — aggregateStatus', () {
    test('sending si todas las partes estan en sending', () {
      final m = ChatMessage('texto', true, false, partIds: [null, null]);
      expect(m.aggregateStatus, MsgStatus.sending);
    });

    test('delivered si todas las partes estan delivered', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', 'B']);
      m.partStatuses[0] = MsgStatus.delivered;
      m.partStatuses[1] = MsgStatus.delivered;
      expect(m.aggregateStatus, MsgStatus.delivered);
    });

    test('failed si alguna parte fallo (aunque otra este delivered)', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', 'B']);
      m.partStatuses[0] = MsgStatus.delivered;
      m.partStatuses[1] = MsgStatus.failed;
      expect(m.aggregateStatus, MsgStatus.failed);
    });

    test('sending si alguna parte esta pendiente y ninguna fallo', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', 'B']);
      m.partStatuses[0] = MsgStatus.delivered;
      m.partStatuses[1] = MsgStatus.sending;
      expect(m.aggregateStatus, MsgStatus.sending);
    });

    test('failed precede a sending si hay una falla y una pendiente', () {
      final m = ChatMessage('texto', true, false,
          partIds: ['A', 'B', 'C']);
      m.partStatuses[0] = MsgStatus.failed;
      m.partStatuses[1] = MsgStatus.sending;
      m.partStatuses[2] = MsgStatus.delivered;
      expect(m.aggregateStatus, MsgStatus.failed);
    });
  });

  group('ChatMessage — aggregateMedium', () {
    test('none si todas las partes estan pendientes', () {
      final m = ChatMessage('texto', true, false, partIds: [null, null]);
      expect(m.aggregateMedium, MsgMedium.none);
    });

    test('lora si todas las partes llegaron por lora', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', 'B']);
      m.partMediums[0] = MsgMedium.lora;
      m.partMediums[1] = MsgMedium.lora;
      expect(m.aggregateMedium, MsgMedium.lora);
    });

    test('broker si alguna parte llego por broker', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', 'B']);
      m.partMediums[0] = MsgMedium.lora;
      m.partMediums[1] = MsgMedium.broker;
      expect(m.aggregateMedium, MsgMedium.broker);
    });

    test('broker si todas llegaron por broker', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', 'B']);
      m.partMediums[0] = MsgMedium.broker;
      m.partMediums[1] = MsgMedium.broker;
      expect(m.aggregateMedium, MsgMedium.broker);
    });

    test('none si una parte es lora y otra sigue pendiente', () {
      final m = ChatMessage('texto', true, false, partIds: ['A', null]);
      m.partMediums[0] = MsgMedium.lora;
      m.partMediums[1] = MsgMedium.none;
      expect(m.aggregateMedium, MsgMedium.none);
    });
  });
}
