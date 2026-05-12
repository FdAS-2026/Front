import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lora_ble_chat/main.dart';

void main() {
  testWidgets('Muestra la pantalla inicial de LoRa BLE Chat', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('LoRa BLE Chat'), findsOneWidget);
    expect(find.text('Sin conexion'), findsOneWidget);
    expect(find.text('Escanear'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
  });
}
