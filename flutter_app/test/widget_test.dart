import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lora_ble_chat/main.dart';

void main() {
  testWidgets('Arranca en la pantalla de vincular placa', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp());
    // Primer frame: sin placa vinculada => pantalla de escaneo/vinculo.
    expect(find.text('Vincular mi placa'), findsOneWidget);
  });
}
