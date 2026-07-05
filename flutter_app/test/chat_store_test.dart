// chat_store_test.dart — encode/decode del historial (UX-01), sin plataforma.

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/chat_store.dart';

void main() {
  test('round-trip preserva contactos y mensajes', () {
    final data = <String, List<Map<String, dynamic>>>{
      '1A2B': [
        {'t': 'hola', 'o': true, 'sy': false, 'st': 1, 'm': 0, 'ts': 123},
        {'t': 'que tal', 'o': false, 'sy': false, 'st': 1, 'm': 1, 'ts': 456},
      ],
      'CCDD': [
        {'t': 'ping', 'o': true, 'sy': false, 'st': 2, 'm': 0, 'ts': 789},
      ],
    };
    final restored = ChatStore.decode(ChatStore.encode(data));
    expect(restored.keys.toSet(), {'1A2B', 'CCDD'});
    expect(restored['1A2B']!.length, 2);
    expect(restored['1A2B']![0]['t'], 'hola');
    expect(restored['1A2B']![1]['o'], false);
    expect(restored['CCDD']![0]['ts'], 789);
  });

  test('vacio -> mapa vacio', () {
    expect(ChatStore.decode(''), isEmpty);
  });

  test('JSON corrupto -> mapa vacio (no crashea)', () {
    expect(ChatStore.decode('{no es json valido'), isEmpty);
    expect(ChatStore.decode('[1,2,3]'), isEmpty);
  });
}
