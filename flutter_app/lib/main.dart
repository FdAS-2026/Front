import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

import 'codec/secure_codec.dart';
import 'codec/rsa_oaep.dart';
import 'codec/demo_keys.dart';
import 'linked_boards_store.dart';

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

String _deviceName(BluetoothDevice device) {
  final String name = device.platformName;
  return name.isEmpty ? "Dispositivo sin nombre" : name;
}

/// Un mensaje del chat con metadatos de origen y de la funcionalidad nueva.
class ChatMessage {
  ChatMessage.incoming(this.text, {this.encrypted = false, this.compressed = false})
      : outgoing = false,
        system = false,
        time = DateTime.now();
  ChatMessage.outgoing(this.text)
      : outgoing = true,
        system = false,
        encrypted = false,
        compressed = false,
        time = DateTime.now();
  ChatMessage.system(this.text)
      : outgoing = false,
        system = true,
        encrypted = false,
        compressed = false,
        time = DateTime.now();

  final String text;
  final bool outgoing;
  final bool system;
  final bool encrypted;
  final bool compressed;
  final DateTime time;

  String get hhmmss => time.toString().substring(11, 19);
}

/// Sesion de un dispositivo LoRa conectado por BLE. La app mantiene varias
/// sesiones activas en simultaneo.
class DeviceSession {
  DeviceSession(this.device);

  final BluetoothDevice device;
  BluetoothCharacteristic? rx;
  BluetoothCharacteristic? tx;
  BluetoothCharacteristic? ctrl;
  final List<ChatMessage> messages = [];
  StreamSubscription<List<int>>? notifySub;
  StreamSubscription<BluetoothConnectionState>? connSub;
  bool connected = true;
  bool linked = false;   // bonding BLE recordado
  bool paired = false;   // emparejada con otra placa (LoRa)

  String get name => _deviceName(device);
  String get id => device.remoteId.toString();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ScanResult> scanResults = [];
  bool isScanning = false;
  StreamSubscription? scanSubscription;

  final List<DeviceSession> sessions = [];
  int activeIndex = -1;

  final TextEditingController messageController = TextEditingController();

  // Funcionalidad nueva: descifrado (RSA-2048 OAEP) y descompresion en la app.
  bool secureMode = false;
  // Clave privada en PEM (demo). En produccion se carga desde un secret store.
  String privateKeyPem = DemoKeys.privateKeyPem;
  late SecureCodec codec = _buildCodec();

  SecureCodec _buildCodec() {
    return SecureCodec(
      rsa: RsaOaep.fromPem(privateKeyPem: privateKeyPem),
    );
  }

  static const String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String rxUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String txUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String ctrlUuid = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E";

  final LinkedBoardsStore linkedStore = LinkedBoardsStore();
  Set<String> linkedIds = {};

  DeviceSession? get activeSession =>
      (activeIndex >= 0 && activeIndex < sessions.length)
          ? sessions[activeIndex]
          : null;

  @override
  void initState() {
    super.initState();
    requestPermissions();
    _loadLinked();
  }

  Future<void> _loadLinked() async {
    final boards = await linkedStore.load();
    if (!mounted) return;
    setState(() => linkedIds = boards.map((b) => b.id).toSet());
  }

  Future<void> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.location.request();
    }
  }

  bool _alreadyConnected(BluetoothDevice device) {
    return sessions.any((s) => s.id == device.remoteId.toString());
  }

  void startScan() {
    setState(() {
      isScanning = true;
      scanResults.clear();
    });

    _bumpScanner();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        scanResults = results
            .where((r) => _deviceName(r.device).contains("LoRA_N"))
            .where((r) => !_alreadyConnected(r.device))
            .toList();
      });
      _bumpScanner();
    });

    Future.delayed(const Duration(seconds: 5), () {
      FlutterBluePlus.stopScan();
      if (mounted) {
        setState(() {
          isScanning = false;
        });
        _bumpScanner();
      }
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_alreadyConnected(device)) {
      _selectByDevice(device);
      return;
    }

    final session = DeviceSession(device);
    setState(() {
      sessions.add(session);
      activeIndex = sessions.length - 1;
      session.messages.add(ChatMessage.system("Conectando a ${session.name}..."));
    });

    try {
      await device.connect();
      _setSession(session, () {
        session.connected = true;
        session.messages.add(ChatMessage.system("Conectado a ${session.name}"));
      });

      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toUpperCase() != serviceUuid.toUpperCase()) {
          continue;
        }
        for (final c in service.characteristics) {
          final uuid = c.uuid.toString().toUpperCase();
          if (uuid == rxUuid.toUpperCase()) {
            session.rx = c;
          }
          if (uuid == ctrlUuid.toUpperCase()) {
            session.ctrl = c;
          }
          if (uuid == txUuid.toUpperCase()) {
            session.tx = c;
            await c.setNotifyValue(true);
            session.notifySub = c.onValueReceived.listen((value) {
              _onIncoming(session, value);
            });
          }
        }
      }

      _setSession(session, () {
        session.linked = linkedIds.contains(session.id);
      });

      session.connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _setSession(session, () {
            session.connected = false;
            session.messages.add(ChatMessage.system("Desconectado"));
          });
        }
      });
    } catch (e) {
      _setSession(session, () {
        session.messages.add(ChatMessage.system("Error: $e"));
      });
    }
  }

  void _onIncoming(DeviceSession session, List<int> value) {
    // Notificacion de estado de emparejamiento desde la placa.
    final asText = String.fromCharCodes(value);
    if (asText.startsWith("PAIRED:")) {
      _setSession(session, () {
        session.paired = true;
        session.messages.add(
          ChatMessage.system("Emparejada con ${asText.substring(7)}"),
        );
      });
      return;
    }

    final decoded = codec.decode(
      value,
      secure: secureMode,
    );
    _setSession(session, () {
      session.messages.add(ChatMessage.incoming(
        decoded.text,
        encrypted: decoded.wasEncrypted,
        compressed: decoded.wasCompressed,
      ));
    });
  }

  // Aplica cambios en una sesion y refresca solo si sigue montada.
  void _setSession(DeviceSession session, VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  Future<void> sendMessage(String text) async {
    final session = activeSession;
    if (session == null) return;
    if (session.rx == null) {
      setState(() {
        session.messages.add(ChatMessage.system("Caracteristica RX no encontrada"));
      });
      return;
    }
    try {
      await session.rx!.write(text.codeUnits);
      setState(() {
        session.messages.add(ChatMessage.outgoing(text));
      });
      messageController.clear();
    } catch (e) {
      setState(() {
        session.messages.add(ChatMessage.system("Error al enviar: $e"));
      });
    }
  }

  void disconnectSession(DeviceSession session) {
    session.notifySub?.cancel();
    session.connSub?.cancel();
    try {
      session.device.disconnect();
    } catch (_) {}
    setState(() {
      sessions.remove(session);
      if (activeIndex >= sessions.length) {
        activeIndex = sessions.length - 1;
      }
    });
  }

  void _selectByDevice(BluetoothDevice device) {
    final idx = sessions.indexWhere((s) => s.id == device.remoteId.toString());
    if (idx >= 0) setState(() => activeIndex = idx);
  }

  Future<void> _sendCtrl(DeviceSession session, String cmd) async {
    final ctrl = session.ctrl;
    if (ctrl == null) {
      setState(() => session.messages
          .add(ChatMessage.system("Esta placa no acepta comandos de control")));
      return;
    }
    await ctrl.write(cmd.codeUnits);
  }

  // Enlaza la placa con este telefono (bonding BLE) y la recuerda.
  Future<void> linkBoard(DeviceSession session) async {
    try {
      await session.device.createBond(); // Android: dispara el PIN del sistema
    } catch (_) {
      // iOS empareja al acceder a una caracteristica cifrada; se ignora.
    }
    await linkedStore.add(session.id, session.name);
    setState(() {
      linkedIds.add(session.id);
      session.linked = true;
      session.messages.add(ChatMessage.system("Placa enlazada a este telefono"));
    });
  }

  // Quita el enlace: avisa a la placa (borra bond), remueve bond local y olvida.
  Future<void> unlinkBoard(DeviceSession session) async {
    try {
      await _sendCtrl(session, "UNLINK");
    } catch (_) {}
    try {
      await session.device.removeBond();
    } catch (_) {}
    await linkedStore.remove(session.id);
    setState(() {
      linkedIds.remove(session.id);
      session.linked = false;
      session.messages.add(ChatMessage.system("Enlace removido"));
    });
  }

  // Emparejar dos placas: envia el mismo PIN a todas las placas conectadas.
  Future<void> _pairBoardsWithPin(String pin) async {
    final connected = sessions.where((s) => s.connected).toList();
    for (final s in connected) {
      await _sendCtrl(s, "PAIR:$pin");
      _setSession(s, () => s.messages.add(
            ChatMessage.system("Emparejando con PIN $pin..."),
          ));
    }
  }

  Future<void> unpairBoard(DeviceSession session) async {
    await _sendCtrl(session, "UNPAIR");
    setState(() {
      session.paired = false;
      session.messages.add(ChatMessage.system("Emparejamiento deshecho"));
    });
  }

  void _openPairDialog() {
    final pinCtrl = TextEditingController();
    final connectedCount = sessions.where((s) => s.connected).length;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Emparejar placas"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              connectedCount < 2
                  ? "Conecta las dos placas que quieras emparejar y elige un PIN."
                  : "Se enviara el PIN a las $connectedCount placas conectadas. "
                      "Las que compartan el PIN quedaran emparejadas.",
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: const InputDecoration(
                labelText: "PIN de emparejamiento",
                hintText: "p. ej. 1234",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("Cancelar"),
          ),
          FilledButton(
            onPressed: () {
              final pin = pinCtrl.text.trim();
              if (pin.isNotEmpty) {
                Navigator.of(ctx).pop();
                _pairBoardsWithPin(pin);
              }
            },
            child: const Text("Emparejar"),
          ),
        ],
      ),
    );
  }

  void _openScannerSheet() {
    startScan();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ScannerSheet(
        onConnect: (device) {
          Navigator.of(context).pop();
          connectToDevice(device);
        },
        listenable: _scannerNotifier,
        stateOf: () => (isScanning, scanResults),
        onRescan: startScan,
      ),
    );
  }

  // Notificador simple para refrescar la hoja de escaneo.
  final _scannerNotifier = ValueNotifier<int>(0);

  void _bumpScanner() => _scannerNotifier.value++;

  void _openSettings() {
    final keyCtrl = TextEditingController(text: privateKeyPem);
    showDialog<void>(
      context: context,
      builder: (ctx) {
        bool localSecure = secureMode;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text("Modo seguro"),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Descifrar y descomprimir"),
                    subtitle: const Text(
                      "Descifra mensajes RSA-2048 (OAEP) en base64 y descomprime "
                      "Huffman al recibir.",
                    ),
                    value: localSecure,
                    onChanged: (v) => setLocal(() => localSecure = v),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: keyCtrl,
                    minLines: 3,
                    maxLines: 6,
                    style: const TextStyle(fontSize: 11, fontFamily: "monospace"),
                    decoration: const InputDecoration(
                      labelText: "Clave privada (PEM)",
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text("Cancelar"),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    secureMode = localSecure;
                    privateKeyPem = keyCtrl.text.trim();
                    codec = _buildCodec();
                  });
                  Navigator.of(ctx).pop();
                },
                child: const Text("Guardar"),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    scanSubscription?.cancel();
    for (final s in sessions) {
      s.notifySub?.cancel();
      s.connSub?.cancel();
    }
    messageController.dispose();
    _scannerNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSessions = sessions.isNotEmpty;
    final active = activeSession;

    return Scaffold(
      appBar: AppBar(
        title: const Text("LoRa BLE Chat"),
        actions: [
          IconButton(
            tooltip: secureMode ? "Modo seguro activo" : "Modo seguro",
            onPressed: _openSettings,
            icon: Icon(secureMode ? Icons.lock : Icons.lock_open),
            color: secureMode ? const Color(0xFF16A34A) : null,
          ),
          PopupMenuButton<String>(
            tooltip: "Enlace y emparejamiento",
            icon: const Icon(Icons.link),
            onSelected: (value) {
              switch (value) {
                case 'pair':
                  _openPairDialog();
                  break;
                case 'link':
                  if (active != null) linkBoard(active);
                  break;
                case 'unlink':
                  if (active != null) unlinkBoard(active);
                  break;
                case 'unpair':
                  if (active != null) unpairBoard(active);
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'pair',
                child: ListTile(
                  leading: Icon(Icons.cable),
                  title: Text("Emparejar placas (PIN)"),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (active != null) const PopupMenuDivider(),
              if (active != null && !active.linked)
                const PopupMenuItem(
                  value: 'link',
                  child: ListTile(
                    leading: Icon(Icons.add_link),
                    title: Text("Enlazar placa activa"),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (active != null && active.linked)
                const PopupMenuItem(
                  value: 'unlink',
                  child: ListTile(
                    leading: Icon(Icons.link_off),
                    title: Text("Desenlazar placa activa"),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (active != null && active.paired)
                const PopupMenuItem(
                  value: 'unpair',
                  child: ListTile(
                    leading: Icon(Icons.cancel),
                    title: Text("Desemparejar placa activa"),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      floatingActionButton: hasSessions
          ? FloatingActionButton.extended(
              onPressed: _openScannerSheet,
              icon: const Icon(Icons.add),
              label: const Text("Dispositivo"),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _ConnectionPanel(
                sessionCount: sessions.where((s) => s.connected).length,
                activeName: active?.name,
                isScanning: isScanning,
                onScan: startScan,
              ),
            ),
            if (hasSessions)
              _DeviceSelector(
                sessions: sessions,
                activeIndex: activeIndex,
                onSelect: (i) => setState(() => activeIndex = i),
                onClose: (s) => disconnectSession(s),
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: !hasSessions
                    ? _ScannerView(
                        key: const ValueKey("scanner"),
                        isScanning: isScanning,
                        scanResults: scanResults,
                        onConnect: connectToDevice,
                        onScan: startScan,
                      )
                    : _ChatView(
                        key: ValueKey("chat-${active?.id}"),
                        messages: active?.messages ?? const [],
                      ),
              ),
            ),
            if (hasSessions && active != null && active.connected)
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
    required this.sessionCount,
    required this.activeName,
    required this.isScanning,
    required this.onScan,
  });

  final int sessionCount;
  final String? activeName;
  final bool isScanning;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final bool isConnected = sessionCount > 0;
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
                  isConnected
                      ? (sessionCount == 1
                          ? "1 dispositivo conectado"
                          : "$sessionCount dispositivos conectados")
                      : "Sin conexion",
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isConnected
                      ? "Activo: ${activeName ?? '-'}"
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
          if (!isConnected)
            FilledButton.icon(
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

/// Selector horizontal de los dispositivos conectados (chips).
class _DeviceSelector extends StatelessWidget {
  const _DeviceSelector({
    required this.sessions,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
  });

  final List<DeviceSession> sessions;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<DeviceSession> onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: sessions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final s = sessions[index];
          final selected = index == activeIndex;
          final Color base =
              s.connected ? const Color(0xFF2563EB) : Colors.grey;
          return GestureDetector(
            onTap: () => onSelect(index),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: selected ? base : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? base : const Color(0xFFE5E7EB),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    s.connected ? Icons.memory : Icons.link_off,
                    size: 16,
                    color: selected ? Colors.white : base,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    s.name,
                    style: TextStyle(
                      color: selected ? Colors.white : const Color(0xFF111827),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  if (s.linked) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.lock,
                        size: 13,
                        color: selected ? Colors.white : const Color(0xFF16A34A)),
                  ],
                  if (s.paired) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.cable,
                        size: 13,
                        color: selected ? Colors.white : const Color(0xFF2563EB)),
                  ],
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => onClose(s),
                    child: Icon(
                      Icons.close,
                      size: 15,
                      color: selected
                          ? Colors.white70
                          : Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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

/// Hoja inferior para escanear y agregar dispositivos sin perder los activos.
class _ScannerSheet extends StatelessWidget {
  const _ScannerSheet({
    required this.onConnect,
    required this.listenable,
    required this.stateOf,
    required this.onRescan,
  });

  final ValueChanged<BluetoothDevice> onConnect;
  final Listenable listenable;
  final (bool, List<ScanResult>) Function() stateOf;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF6F8FC),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.only(top: 12),
          child: AnimatedBuilder(
            animation: listenable,
            builder: (context, _) {
              final (scanning, results) = stateOf();
              return Column(
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      "Agregar dispositivo",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _ScannerView(
                      isScanning: scanning,
                      scanResults: results,
                      onConnect: onConnect,
                      onScan: onRescan,
                    ),
                  ),
                ],
              );
            },
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
  });

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const _EmptyState(
        icon: Icons.forum_outlined,
        title: "Sin mensajes",
        subtitle: "Envia un mensaje para iniciar la conversacion con este nodo.",
      );
    }

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final ChatMessage message = messages[messages.length - 1 - index];

        if (message.system) {
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
                  message.text,
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

        final bool outgoing = message.outgoing;

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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.text,
                        style: TextStyle(
                          color: outgoing
                              ? Colors.white
                              : const Color(0xFF172033),
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (message.encrypted || message.compressed) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (message.encrypted)
                              const _Tag(icon: Icons.lock, label: "Descifrado"),
                            if (message.encrypted && message.compressed)
                              const SizedBox(width: 6),
                            if (message.compressed)
                              const _Tag(
                                  icon: Icons.compress,
                                  label: "Descomprimido"),
                          ],
                        ),
                      ],
                    ],
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

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF16A34A).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFF16A34A)),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF16A34A),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
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
