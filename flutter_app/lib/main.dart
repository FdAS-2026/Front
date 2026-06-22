import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

import 'board_link_store.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF2563EB);
    return MaterialApp(
      title: 'LoRa Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: seedColor, brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF6F8FC),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: Color(0xFF172033),
          titleTextStyle: TextStyle(
              color: Color(0xFF172033), fontSize: 20, fontWeight: FontWeight.w800),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
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

/// Un mensaje del chat con un contacto.
class ChatMessage {
  ChatMessage(this.text, this.outgoing, this.system) : time = DateTime.now();
  final String text;
  final bool outgoing;
  final bool system;
  final DateTime time;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // BLE / servicio del firmware.
  static const String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String txUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String ctrlUuid = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E";

  final BoardLinkStore _store = BoardLinkStore();

  // Conexion a la placa propia (identidad).
  BluetoothDevice? board;
  BluetoothCharacteristic? _ctrl;
  StreamSubscription? _notifySub;
  StreamSubscription? _connSub;
  StreamSubscription? _scanSub;
  bool connecting = false;
  bool isScanning = false;
  List<ScanResult> scanResults = [];

  // Identidad propia.
  String myId = "";
  String myName = "";

  // Contactos: id -> nombre. Mensajes por contacto.
  final Map<String, String> contacts = {};
  final Map<String, List<ChatMessage>> chats = {};
  String? openContact; // contacto cuyo chat esta abierto

  final TextEditingController _msgCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.location.request();
    }
    final saved = await _store.load();
    if (saved != null) {
      _connectTo(BluetoothDevice.fromId(saved));
    }
  }

  // ==================== Escaneo / vinculo ====================
  void startScan() {
    setState(() {
      isScanning = true;
      scanResults = [];
    });
    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 5),
      withServices: [Guid(serviceUuid)],
    );
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() => scanResults = results);
    });
    Future.delayed(const Duration(seconds: 6), () {
      FlutterBluePlus.stopScan();
      if (mounted) setState(() => isScanning = false);
    });
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    setState(() => connecting = true);
    try {
      await device.connect(timeout: const Duration(seconds: 15));
      // Bonding (enlace BLE con passkey en la OLED). Idempotente.
      try {
        await device.createBond();
      } catch (_) {}

      final services = await device.discoverServices();
      for (final s in services) {
        if (s.uuid.toString().toUpperCase() != serviceUuid.toUpperCase()) continue;
        for (final c in s.characteristics) {
          final u = c.uuid.toString().toUpperCase();
          if (u == txUuid.toUpperCase()) {
            await c.setNotifyValue(true);
            _notifySub = c.onValueReceived.listen(_onEvent);
          }
          if (u == ctrlUuid.toUpperCase()) _ctrl = c;
        }
      }

      _connSub = device.connectionState.listen((st) {
        if (st == BluetoothConnectionState.disconnected && mounted) {
          setState(() => board = null);
        }
      });

      await _store.save(device.remoteId.str);
      setState(() {
        board = device;
        connecting = false;
      });
      // Pedir identidad y contactos.
      await _send("WHOAMI");
      await Future.delayed(const Duration(milliseconds: 300));
      await _send("LIST");
    } catch (e) {
      setState(() => connecting = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error de conexion: $e")));
      }
    }
  }

  Future<void> _send(String cmd) async {
    final c = _ctrl;
    if (c == null) return;
    await c.write(cmd.codeUnits, withoutResponse: false);
  }

  // ==================== Eventos desde la placa ====================
  void _onEvent(List<int> value) {
    final msg = String.fromCharCodes(value);
    final i = msg.indexOf(':');
    final tag = i < 0 ? msg : msg.substring(0, i);
    final rest = i < 0 ? "" : msg.substring(i + 1);

    switch (tag) {
      case "ME":
        final p = rest.split(':');
        setState(() {
          myId = p.isNotEmpty ? p[0] : "";
          myName = p.length > 1 ? p[1] : "";
        });
        break;
      case "NAME":
        setState(() => myName = rest);
        break;
      case "CONTACTS":
        setState(() {
          contacts.clear();
          for (final entry in rest.split(',')) {
            final kv = entry.split('=');
            if (kv.length == 2 && kv[0].isNotEmpty) contacts[kv[0]] = kv[1];
          }
        });
        break;
      case "PAIRED":
        final p = rest.split(':');
        if (p.isNotEmpty) {
          setState(() => contacts[p[0]] = p.length > 1 ? p[1] : p[0]);
        }
        _send("LIST");
        break;
      case "UNPAIRED":
        setState(() {
          contacts.remove(rest);
          chats.remove(rest);
        });
        break;
      case "MSG":
        final j = rest.indexOf(':');
        if (j > 0) {
          final src = rest.substring(0, j);
          final text = rest.substring(j + 1);
          setState(() {
            chats.putIfAbsent(src, () => []).add(ChatMessage(text, false, false));
          });
        }
        break;
      case "ERR":
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("Placa: $rest")));
        }
        break;
    }
  }

  // ==================== Acciones ====================
  void _sendMessage(String contactId) {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _send("SEND:$contactId:$text");
    setState(() {
      chats.putIfAbsent(contactId, () => []).add(ChatMessage(text, true, false));
    });
    _msgCtrl.clear();
  }

  void _pairDialog() {
    final pin = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Agregar contacto"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              "Acordá un PIN con la otra persona. Ambos lo ingresan al mismo tiempo para emparejar sus placas.",
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
              controller: pin,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "PIN")),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          FilledButton(
              onPressed: () {
                if (pin.text.trim().isNotEmpty) {
                  _send("PAIR:${pin.text.trim()}");
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text("Emparejando... que la otra placa use el mismo PIN")));
                }
              },
              child: const Text("Emparejar")),
        ],
      ),
    );
  }

  void _renameDialog() {
    final n = TextEditingController(text: myName);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nombre de mi placa"),
        content: TextField(
            controller: n,
            maxLength: 20,
            decoration: const InputDecoration(labelText: "Nombre")),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          FilledButton(
              onPressed: () {
                final nm = n.text.trim();
                if (nm.isNotEmpty) {
                  _send("SETNAME:$nm");
                  setState(() => myName = nm);
                }
                Navigator.pop(ctx);
              },
              child: const Text("Guardar")),
        ],
      ),
    );
  }

  Future<void> _unlinkBoard() async {
    try {
      await board?.removeBond();
    } catch (_) {}
    try {
      await board?.disconnect();
    } catch (_) {}
    await _store.clear();
    setState(() {
      board = null;
      myId = "";
      myName = "";
      contacts.clear();
      chats.clear();
    });
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _scanSub?.cancel();
    _msgCtrl.dispose();
    super.dispose();
  }

  // ==================== UI ====================
  @override
  Widget build(BuildContext context) {
    if (board == null) return _scaffoldScanner();
    if (openContact != null) return _scaffoldChat(openContact!);
    return _scaffoldHome();
  }

  Scaffold _scaffoldScanner() {
    return Scaffold(
      appBar: AppBar(title: const Text("Vincular mi placa")),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              connecting
                  ? "Conectando..."
                  : "Elegí tu placa. Será tu identidad: la app se enlaza a una sola.",
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            child: scanResults.isEmpty
                ? _EmptyState(
                    icon: Icons.sensors,
                    title: isScanning ? "Buscando placas..." : "Sin placas",
                    subtitle: "Encendé tu placa y escaneá.",
                    showLoader: isScanning,
                    actionLabel: isScanning ? null : "Escanear",
                    onAction: isScanning ? null : startScan,
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: scanResults.map((r) {
                      final name = r.device.platformName.isEmpty
                          ? r.device.remoteId.str
                          : r.device.platformName;
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.memory, color: Color(0xFF2563EB)),
                          title: Text(name),
                          subtitle: Text("${r.device.remoteId.str}  ${r.rssi} dBm"),
                          trailing: FilledButton(
                            onPressed:
                                connecting ? null : () => _connectTo(r.device),
                            child: const Text("Vincular"),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
          ),
        ]),
      ),
      floatingActionButton: scanResults.isNotEmpty && !isScanning
          ? FloatingActionButton.extended(
              onPressed: startScan,
              icon: const Icon(Icons.refresh),
              label: const Text("Reescanear"))
          : null,
    );
  }

  Scaffold _scaffoldHome() {
    final ids = contacts.keys.toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(children: [
          Text(myName.isEmpty ? "Mi placa" : myName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          if (myId.isNotEmpty)
            Text("ID $myId",
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ]),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _renameDialog();
              if (v == 'unlink') _unlinkBoard();
              if (v == 'refresh') _send("LIST");
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text("Renombrar mi placa")),
              PopupMenuItem(value: 'refresh', child: Text("Actualizar contactos")),
              PopupMenuItem(value: 'unlink', child: Text("Desvincular placa")),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ids.isEmpty
            ? _EmptyState(
                icon: Icons.group_add,
                title: "Sin contactos",
                subtitle: "Agregá un contacto emparejando con otra placa por PIN.",
                actionLabel: "Agregar contacto",
                onAction: _pairDialog,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: ids.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final id = ids[i];
                  final last = (chats[id]?.isNotEmpty ?? false)
                      ? chats[id]!.last.text
                      : "Tocá para chatear";
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                          backgroundColor: const Color(0xFFDBEAFE),
                          child: Text(contacts[id]!.isNotEmpty
                              ? contacts[id]![0].toUpperCase()
                              : "?")),
                      title: Text(contacts[id]!),
                      subtitle: Text(last,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text("ID $id",
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500)),
                      onTap: () => setState(() => openContact = id),
                    ),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _pairDialog,
          icon: const Icon(Icons.person_add),
          label: const Text("Contacto")),
    );
  }

  Scaffold _scaffoldChat(String id) {
    final msgs = chats[id] ?? [];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => openContact = null)),
        title: Text(contacts[id] ?? id),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: msgs.isEmpty
                ? const _EmptyState(
                    icon: Icons.lock,
                    title: "Conversacion cifrada E2E",
                    subtitle: "Los mensajes se cifran de placa a placa.")
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: msgs.length,
                    itemBuilder: (_, idx) {
                      final m = msgs[msgs.length - 1 - idx];
                      return Align(
                        alignment: m.outgoing
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.75),
                          decoration: BoxDecoration(
                            color: m.outgoing
                                ? const Color(0xFF2563EB)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(m.text,
                              style: TextStyle(
                                  color: m.outgoing
                                      ? Colors.white
                                      : const Color(0xFF172033))),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  decoration:
                      const InputDecoration(hintText: "Mensaje cifrado..."),
                  onSubmitted: (_) => _sendMessage(id),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => _sendMessage(id),
                  child: const Icon(Icons.send)),
            ]),
          ),
        ]),
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
                color: const Color(0xFFDBEAFE),
                borderRadius: BorderRadius.circular(24)),
            child: Icon(icon, color: const Color(0xFF2563EB), size: 34),
          ),
          const SizedBox(height: 18),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF111827))),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, height: 1.4)),
          if (showLoader) ...[
            const SizedBox(height: 20),
            const CircularProgressIndicator()
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.radar),
                label: Text(actionLabel!)),
          ],
        ]),
      ),
    );
  }
}
