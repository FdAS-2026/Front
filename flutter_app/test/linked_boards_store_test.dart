import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/linked_boards_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = LinkedBoardsStore();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('lista vacia al inicio', () async {
    expect(await store.load(), isEmpty);
  });

  test('agrega y persiste una placa', () async {
    await store.add('AA:BB', 'LoRA_N1');
    final boards = await store.load();
    expect(boards.length, 1);
    expect(boards.first.id, 'AA:BB');
    expect(boards.first.name, 'LoRA_N1');
    expect(await store.isLinked('AA:BB'), isTrue);
  });

  test('no duplica; actualiza el nombre', () async {
    await store.add('AA:BB', 'LoRA_N1');
    await store.add('AA:BB', 'LoRA_N2');
    final boards = await store.load();
    expect(boards.length, 1);
    expect(boards.first.name, 'LoRA_N2');
  });

  test('remueve una placa', () async {
    await store.add('AA:BB', 'LoRA_N1');
    await store.add('CC:DD', 'LoRA_N2');
    await store.remove('AA:BB');
    final boards = await store.load();
    expect(boards.length, 1);
    expect(boards.first.id, 'CC:DD');
    expect(await store.isLinked('AA:BB'), isFalse);
  });
}
