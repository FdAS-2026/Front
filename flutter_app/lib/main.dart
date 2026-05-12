import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF2563EB);

    return MaterialApp(
      title: 'LoRa BLE Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F8FC),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: Color(0xFF172033),
          titleTextStyle: TextStyle(
            color: Color(0xFF172033),
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
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

String _deviceName(BluetoothDevice device) {
  final String name = device.platformName;
  return name.isEmpty ? "Dispositivo sin nombre" : name;
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

  static const String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String rxUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String txUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  @override
  void initState() {
    super.initState();
    requestPermissions();
  }

  Future<void> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
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
            .where((r) => _deviceName(r.device).contains("LoRA_N"))
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
        messages.add("Sistema: Conectado a ${_deviceName(device)}");
      });

      // Obtener servicios
      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() ==
            serviceUuid.toUpperCase()) {
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() ==
                rxUuid.toUpperCase()) {
              rxCharacteristic = characteristic;
            }
            if (characteristic.uuid.toString().toUpperCase() ==
                txUuid.toUpperCase()) {
              txCharacteristic = characteristic;
              // Escuchar notificaciones
              await characteristic.setNotifyValue(true);
              notificationSubscription =
                  characteristic.onValueReceived.listen((value) {
                String message = String.fromCharCodes(value);
                setState(() {
                  messages.add(
                    "Recibido ${DateTime.now().toString().substring(11, 19)}: $message",
                  );
                });
              });
            }
          }
        }
      }

      // Monitorear desconexion
      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            connectedDevice = null;
            messages.add("Sistema: Desconectado");
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
        messages.add("Aviso: Caracteristica RX no encontrada");
      });
      return;
    }

    try {
      List<int> bytes = text.codeUnits;
      await rxCharacteristic!.write(bytes);
      setState(() {
        messages.add(
          "Enviado ${DateTime.now().toString().substring(11, 19)}: $text",
        );
      });
      messageController.clear();
    } catch (e) {
      setState(() {
        messages.add("Error al enviar: $e");
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

  bool _isOutgoingMessage(String message) {
    return message.startsWith("Enviado");
  }

  bool _isSystemMessage(String message) {
    return message.startsWith("Sistema") ||
        message.startsWith("Aviso") ||
        message.startsWith("Error");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LoRa BLE Chat"),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _ConnectionPanel(
                connectedDevice: connectedDevice,
                isScanning: isScanning,
                onScan: startScan,
                onDisconnect: disconnectDevice,
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: connectedDevice == null
                    ? _ScannerView(
                        key: const ValueKey("scanner"),
                        isScanning: isScanning,
                        scanResults: scanResults,
                        onConnect: connectToDevice,
                        onScan: startScan,
                      )
                    : _ChatView(
                        key: const ValueKey("chat"),
                        messages: messages,
                        isOutgoingMessage: _isOutgoingMessage,
                        isSystemMessage: _isSystemMessage,
                      ),
              ),
            ),
            if (connectedDevice != null)
              _MessageInput(
                controller: messageController,
                onSend: sendMessage,
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({
    required this.connectedDevice,
    required this.isScanning,
    required this.onScan,
    required this.onDisconnect,
  });

  final BluetoothDevice? connectedDevice;
  final bool isScanning;
  final VoidCallback onScan;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final bool isConnected = connectedDevice != null;
    final Color accent = isConnected ? const Color(0xFF16A34A) : Colors.orange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isConnected ? "Conexion activa" : "Sin conexion",
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isConnected
                      ? _deviceName(connectedDevice!)
                      : isScanning
                          ? "Buscando dispositivos LoRa cercanos"
                          : "Listo para escanear dispositivos BLE",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          isConnected
              ? FilledButton.tonalIcon(
                  onPressed: onDisconnect,
                  icon: const Icon(Icons.link_off, size: 18),
                  label: const Text("Salir"),
                  style: FilledButton.styleFrom(
                    foregroundColor: const Color(0xFFB91C1C),
                    backgroundColor: const Color(0xFFFEE2E2),
                  ),
                )
              : FilledButton.icon(
                  onPressed: isScanning ? null : onScan,
                  icon: isScanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar, size: 18),
                  label: Text(isScanning ? "Buscando" : "Escanear"),
                ),
        ],
      ),
    );
  }
}

class _ScannerView extends StatelessWidget {
  const _ScannerView({
    super.key,
    required this.isScanning,
    required this.scanResults,
    required this.onConnect,
    required this.onScan,
  });

  final bool isScanning;
  final List<ScanResult> scanResults;
  final ValueChanged<BluetoothDevice> onConnect;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    if (isScanning) {
      return const _EmptyState(
        icon: Icons.bluetooth_searching,
        title: "Escaneando...",
        subtitle: "Mantente cerca del modulo LoRa mientras buscamos senal BLE.",
        showLoader: true,
      );
    }

    if (scanResults.isEmpty) {
      return _EmptyState(
        icon: Icons.sensors,
        title: "No hay dispositivos LoRa",
        subtitle: "Presiona escanear para buscar nodos LoRa_N disponibles.",
        actionLabel: "Escanear ahora",
        onAction: onScan,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      itemCount: scanResults.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final ScanResult result = scanResults[index];

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFDBEAFE),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.memory,
                  color: Color(0xFF2563EB),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _deviceName(result.device),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      result.device.remoteId.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _SignalBadge(rssi: result.rssi),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => onConnect(result.device),
                child: const Text("Conectar"),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SignalBadge extends StatelessWidget {
  const _SignalBadge({required this.rssi});

  final int rssi;

  @override
  Widget build(BuildContext context) {
    final bool strongSignal = rssi >= -70;
    final Color color =
        strongSignal ? const Color(0xFF16A34A) : const Color(0xFFF59E0B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.signal_cellular_alt, color: color, size: 14),
          const SizedBox(width: 5),
          Text(
            "$rssi dBm",
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatView extends StatelessWidget {
  const _ChatView({
    super.key,
    required this.messages,
    required this.isOutgoingMessage,
    required this.isSystemMessage,
  });

  final List<String> messages;
  final bool Function(String message) isOutgoingMessage;
  final bool Function(String message) isSystemMessage;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final String message = messages[messages.length - 1 - index];
        final bool outgoing = isOutgoingMessage(message);
        final bool system = isSystemMessage(message);

        if (system) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFF1E40AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Align(
            alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: outgoing ? const Color(0xFF2563EB) : Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(outgoing ? 18 : 6),
                    bottomRight: Radius.circular(outgoing ? 6 : 18),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Text(
                    message,
                    style: TextStyle(
                      color: outgoing ? Colors.white : const Color(0xFF172033),
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MessageInput extends StatelessWidget {
  const _MessageInput({
    required this.controller,
    required this.onSend,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSend;

  void _sendIfReady() {
    final String text = controller.text.trim();
    if (text.isNotEmpty) {
      onSend(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration(
                hintText: "Escribe un mensaje...",
                prefixIcon: Icon(Icons.chat_bubble_outline),
              ),
              onSubmitted: (_) => _sendIfReady(),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 52,
            height: 52,
            child: FilledButton(
              onPressed: _sendIfReady,
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Icon(Icons.send_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.showLoader = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool showLoader;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: const Color(0xFFDBEAFE),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                icon,
                color: const Color(0xFF2563EB),
                size: 34,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF111827),
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade600,
                height: 1.4,
              ),
            ),
            if (showLoader) ...[
              const SizedBox(height: 20),
              const CircularProgressIndicator(),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.radar),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
