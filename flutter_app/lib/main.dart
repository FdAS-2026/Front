import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoRa BLE Chat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ScanResult> scanResults = [];
  bool isScanning = false;
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? rxCharacteristic;
  BluetoothCharacteristic? txCharacteristic;
  List<String> messages = [];
  TextEditingController messageController = TextEditingController();
  StreamSubscription? scanSubscription;
  StreamSubscription? connectionSubscription;
  StreamSubscription? notificationSubscription;

  static const String SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String RX_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String TX_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  @override
  void initState() {
    super.initState();
    requestPermissions();
  }

  Future<void> requestPermissions() async {
    if (Theme.of(context).platform == TargetPlatform.android) {
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.location.request();
    }
  }

  void startScan() {
    setState(() {
      isScanning = true;
      scanResults.clear();
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        scanResults = results
            .where((r) => r.device.name.contains("LoRA_N"))
            .toList();
      });
    });

    Future.delayed(const Duration(seconds: 5), () {
      FlutterBluePlus.stopScan();
      setState(() {
        isScanning = false;
      });
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() {
        connectedDevice = device;
        messages.clear();
        messages.add("--- Conectado a ${device.name} ---");
      });

      // Obtener servicios
      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() ==
            SERVICE_UUID.toUpperCase()) {
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() ==
                RX_UUID.toUpperCase()) {
              rxCharacteristic = characteristic;
            }
            if (characteristic.uuid.toString().toUpperCase() ==
                TX_UUID.toUpperCase()) {
              txCharacteristic = characteristic;
              // Escuchar notificaciones
              await characteristic.setNotifyValue(true);
              notificationSubscription =
                  characteristic.onValueReceived.listen((value) {
                String message = String.fromCharCodes(value);
                setState(() {
                  messages.add("📨 ${DateTime.now().toString().substring(11, 19)}: $message");
                });
              });
            }
          }
        }
      }

      // Monitorear desconexión
      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            connectedDevice = null;
            messages.add("--- Desconectado ---");
          });
        }
      });
    } catch (e) {
      setState(() {
        messages.add("Error: $e");
      });
    }
  }

  Future<void> sendMessage(String text) async {
    if (rxCharacteristic == null) {
      setState(() {
        messages.add("⚠️ Característica RX no encontrada");
      });
      return;
    }

    try {
      List<int> bytes = text.codeUnits;
      await rxCharacteristic!.write(bytes);
      setState(() {
        messages.add("📤 ${DateTime.now().toString().substring(11, 19)}: $text");
      });
      messageController.clear();
    } catch (e) {
      setState(() {
        messages.add("❌ Error al enviar: $e");
      });
    }
  }

  void disconnectDevice() {
    if (connectedDevice != null) {
      connectedDevice!.disconnect();
      setState(() {
        connectedDevice = null;
        rxCharacteristic = null;
        txCharacteristic = null;
      });
    }
    notificationSubscription?.cancel();
    connectionSubscription?.cancel();
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    scanSubscription?.cancel();
    notificationSubscription?.cancel();
    connectionSubscription?.cancel();
    messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LoRa BLE Chat"),
        centerTitle: true,
        backgroundColor: Colors.blueAccent,
      ),
      body: Column(
        children: [
          // Estado de conexión
          Container(
            padding: const EdgeInsets.all(16),
            color: connectedDevice != null
                ? Colors.greenAccent
                : Colors.grey.shade300,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  connectedDevice != null
                      ? "Conectado: ${connectedDevice!.name}"
                      : "Desconectado",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (connectedDevice != null)
                  ElevatedButton(
                    onPressed: disconnectDevice,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    child: const Text("Desconectar"),
                  )
                else
                  ElevatedButton(
                    onPressed: isScanning ? null : startScan,
                    child: Text(isScanning ? "Escaneando..." : "Escanear"),
                  ),
              ],
            ),
          ),

          // Lista de dispositivos o mensajes
          if (connectedDevice == null)
            Expanded(
              child: isScanning
                  ? const Center(child: CircularProgressIndicator())
                  : scanResults.isEmpty
                      ? const Center(
                          child:
                              Text("No se encontraron dispositivos LoRa\n\nPresiona 'Escanear'"),
                        )
                      : ListView.builder(
                          itemCount: scanResults.length,
                          itemBuilder: (context, index) {
                            ScanResult result = scanResults[index];
                            return ListTile(
                              title: Text(result.device.name),
                              subtitle: Text(
                                result.device.id.toString(),
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: ElevatedButton(
                                onPressed: () =>
                                    connectToDevice(result.device),
                                child: const Text("Conectar"),
                              ),
                            );
                          },
                        ),
            )
          else
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    child: Align(
                      alignment: messages[messages.length - 1 - index]
                              .startsWith("📤")
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: messages[messages.length - 1 - index]
                                  .startsWith("📤")
                              ? Colors.blueAccent
                              : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          messages[messages.length - 1 - index],
                          style: TextStyle(
                            color: messages[messages.length - 1 - index]
                                    .startsWith("📤")
                                ? Colors.white
                                : Colors.black,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // Campo de entrada
          if (connectedDevice != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                border: const Border(
                    top: BorderSide(color: Colors.grey, width: 1)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: messageController,
                      decoration: InputDecoration(
                        hintText: "Escribe un mensaje...",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      onSubmitted: (text) {
                        if (text.isNotEmpty) {
                          sendMessage(text);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (messageController.text.isNotEmpty) {
                        sendMessage(messageController.text);
                      }
                    },
                    icon: const Icon(Icons.send),
                    label: const Text("Enviar"),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
