import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

import 'board_link_store.dart';
import 'chat_store.dart';
import 'codec/chunking.dart';
import 'codec/board_events.dart';

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

enum MsgStatus { sending, delivered, failed }

enum MsgMedium { lora, broker, none }

/// Destino de un SENT pendiente: la burbuja y el índice de parte a los que hay
/// que asignar el msgId cuando llegue el SENT con el cid correspondiente (WR-02).
class _SentTarget {
  final ChatMessage msg;
  final int part;
  const _SentTarget(this.msg, this.part);
}

/// Un mensaje del chat con un contacto.
///
/// Modela N partes (chunks) de un mismo mensaje de usuario. Para mensajes cortos
/// (una sola parte) se comporta igual que antes: lista de 1 elemento.
class ChatMessage {
  ChatMessage(this.text, this.outgoing, this.system,
      {String? msgId,
      this.status = MsgStatus.sending,
      this.medium = MsgMedium.none,
      List<String?>? partIds})
      : partMsgIds = partIds ?? [msgId],
        partStatuses = List.filled((partIds ?? [msgId]).length, MsgStatus.sending),
        partMediums = List.filled((partIds ?? [msgId]).length, MsgMedium.none),
        time = DateTime.now();

  final String text;
  final bool outgoing;
  final bool system;
  final DateTime time;

  // Listas mutables de partes: un slot por chunk del mensaje.
  final List<String?> partMsgIds;
  final List<MsgStatus> partStatuses;
  final List<MsgMedium> partMediums;

  // Campos mutables singulares: compatibilidad con codigo existente.
  // 04-03 los reemplazara por los getters agregados.
  MsgStatus status;
  MsgMedium medium;

  /// Compatibilidad retroactiva: apunta al primer slot de [partMsgIds].
  String? get msgId => partMsgIds.first;
  set msgId(String? v) => partMsgIds[0] = v;

  /// Asigna [id] al primer slot null de [partMsgIds].
  /// Devuelve true si habia un slot libre, false si todos ya tienen id.
  bool assignNextMsgId(String id) {
    final i = partMsgIds.indexOf(null);
    if (i < 0) return false;
    partMsgIds[i] = id;
    return true;
  }

  /// True si alguna parte tiene exactamente este [id].
  bool hasMsgId(String id) => partMsgIds.contains(id);

  /// Estado agregado del mensaje completo.
  /// - todas delivered → delivered
  /// - alguna failed → failed (precede a delivered)
  /// - resto → sending
  MsgStatus get aggregateStatus {
    if (partStatuses.every((s) => s == MsgStatus.delivered)) {
      return MsgStatus.delivered;
    }
    if (partStatuses.any((s) => s == MsgStatus.failed)) {
      return MsgStatus.failed;
    }
    return MsgStatus.sending;
  }

  /// Medio agregado del mensaje completo.
  /// - alguna broker → broker
  /// - todas lora → lora
  /// - con partes pendientes → none
  MsgMedium get aggregateMedium {
    if (partMediums.any((m) => m == MsgMedium.broker)) return MsgMedium.broker;
    if (partMediums.every((m) => m == MsgMedium.lora)) return MsgMedium.lora;
    return MsgMedium.none;
  }

  // UX-01: serialización para persistir el historial. Se guarda el estado
  // agregado (settled); el detalle por-parte es transitorio (solo importa
  // durante la entrega en vivo). Un mensaje restaurado es de una sola parte.
  Map<String, dynamic> toJson() => {
        't': text,
        'o': outgoing,
        'sy': system,
        'st': aggregateStatus.index,
        'm': aggregateMedium.index,
        'ts': time.millisecondsSinceEpoch,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final m = ChatMessage(
      j['t'] as String? ?? '',
      j['o'] as bool? ?? false,
      j['sy'] as bool? ?? false,
    );
    m.status = MsgStatus.values[(j['st'] as int? ?? 0).clamp(0, MsgStatus.values.length - 1)];
    m.medium = MsgMedium.values[(j['m'] as int? ?? 0).clamp(0, MsgMedium.values.length - 1)];
    // Reflejar el estado agregado en la única parte restaurada.
    m.partStatuses[0] = m.status;
    m.partMediums[0] = m.medium;
    return m;
  }
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
  final ChatStore _chatStore = ChatStore();  // UX-01: historial persistente

  // SEC-01: secreto de claim (hex) y token de sesion. El token se obtiene tras
  // responder el desafio; se antepone a cada comando ("<token>|<cmd>").
  String? _claimSecretHex;
  String? _sessionToken;

  // REL-03: acumulador de la lista de contactos fragmentada.
  Map<String, String> _pendingContacts = {};

  // REL-04: control de reconexion automatica.
  bool _userDisconnect = false;  // true si la desconexion fue pedida por el usuario
  bool _reconnecting = false;

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

  // Estado WiFi de la placa (recibido via evento WIFI:<estado>).
  String wifiState = "";
  int? boardBattery;  // UX-02: nivel de bateria de la placa (%), null si desconocido

  // Contactos: id -> nombre. Mensajes por contacto.
  final Map<String, String> contacts = {};
  final Map<String, List<ChatMessage>> chats = {};
  String? openContact; // contacto cuyo chat esta abierto

  final TextEditingController _msgCtrl = TextEditingController();

  // Contador de grupos para mensajes multi-parte (0 para mensajes de 1 parte).
  int _grpCounter = 0;

  // WR-02 fix: correlación exacta SENT→parte. Cada chunk se envía con un cid
  // único; la placa lo devuelve en SENT y así se asigna el msgId a la parte
  // correcta sin forward-scan (que se cruzaba con ráfagas al mismo contacto).
  int _cidCounter = 0;
  final Map<int, _SentTarget> _cidMap = {};

  // Buffer de reensamblado de partes entrantes: clave = "$src:$grp".
  // Cap de 16 grupos activos; grupos incompletos expiran a los 60 s (purga cada 30 s).
  final Map<String, PartGroup> _reassembly = {};

  // Timer de purga del buffer de reensamblado.
  Timer? _purgeTimer;

  @override
  void initState() {
    super.initState();
    _msgCtrl.addListener(() => setState(() {})); // refrescar contador
    _loadChats();  // UX-01: restaurar historial persistido
    _init();
    // Purgar grupos de reensamblado incompletos cada 30 s (timeout de 60 s por grupo).
    _purgeTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeExpiredGroups(),
    );
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

  // ==================== Persistencia del historial (UX-01) ====================
  Future<void> _loadChats() async {
    final data = await _chatStore.load();
    if (data.isEmpty || !mounted) return;
    setState(() {
      chats.clear();
      data.forEach((contactId, msgs) {
        chats[contactId] = msgs.map(ChatMessage.fromJson).toList();
      });
    });
  }

  // Guarda el historial actual. Se llama tras cambios relevantes (mensaje nuevo,
  // ACK/NACK/FAIL, borrado de contacto). Fire-and-forget.
  void _persistChats() {
    final data = <String, List<Map<String, dynamic>>>{};
    chats.forEach((contactId, msgs) {
      data[contactId] = msgs.map((m) => m.toJson()).toList();
    });
    _chatStore.save(data);
  }

  // ==================== Escaneo / vinculo ====================
  void startScan() {
    _scanSub?.cancel();  // cancelar suscripcion anterior para evitar listeners zombie
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
    _userDisconnect = false;  // conexion nueva: habilitar auto-reconexion
    setState(() => connecting = true);
    try {
      // Limpia cualquier bond viejo (de firmwares anteriores) que rompa la
      // conexion por cifrado desincronizado. Las caracteristicas ya no exigen
      // cifrado, asi que no hace falta bondear.
      try {
        await device.removeBond();
      } catch (_) {}

      await device.connect(timeout: const Duration(seconds: 15));

      // Invalida el cache GATT de Android (si la placa cambio de firmware, el
      // cache viejo ocultaria caracteristicas nuevas).
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await device.clearGattCache();
        } catch (_) {}
        // REL-03: pedir un MTU grande para que los eventos BLE no se trunquen.
        try {
          await device.requestMtu(512);
        } catch (_) {}
      }

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
          // La sesion muere con la conexion; el token se renueva al reconectar.
          _sessionToken = null;
          setState(() => board = null);
          // REL-04: si la caida no fue pedida por el usuario, reintentar solo.
          if (!_userDisconnect) _scheduleReconnect(device);
        }
      });

      await _store.save(device.remoteId.str);
      setState(() {
        board = device;
        connecting = false;
      });
      // SEC-01: autenticar la sesion (claim TOFU o desafio). WHOAMI/LIST se
      // envian dentro del flujo, ya con token, al recibir OK:<token>.
      await _beginAuth();
    } catch (e) {
      setState(() => connecting = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Error de conexion: $e")));
      }
    }
  }

  // REL-04: reconexion automatica con backoff exponencial (2,4,8,16,30 s) usando
  // el mismo dispositivo. Se detiene si el usuario reconecta/desvincula a mano o
  // la reconexion tiene exito.
  Future<void> _scheduleReconnect(BluetoothDevice device) async {
    if (_reconnecting) return;
    _reconnecting = true;
    var delaySecs = 2;
    while (mounted && !_userDisconnect && board == null) {
      await Future.delayed(Duration(seconds: delaySecs));
      if (!mounted || _userDisconnect || board != null) break;
      try {
        await _connectTo(device);
      } catch (_) {}
      if (board != null) break;  // reconecto
      delaySecs = (delaySecs * 2).clamp(2, 30);
    }
    _reconnecting = false;
  }

  // Escritura CRUDA (sin token): solo para el handshake (CLAIM, NONCE, AUTH).
  Future<bool> _sendRaw(String cmd) async {
    final c = _ctrl;
    if (c == null) return false;
    try {
      await c.write(utf8.encode(cmd), withoutResponse: false);
      return true;
    } catch (_) {
      return false; // p.ej. BLE aun no listo tras reconectar
    }
  }

  // SEC-01: comando autenticado. Antepone el token de sesion; sin token la placa
  // lo rechazara (ERR:auth). Los comandos de handshake usan _sendRaw.
  Future<bool> _send(String cmd) async {
    final t = _sessionToken;
    return _sendRaw(t != null ? "$t|$cmd" : cmd);
  }

  // La 1a escritura tras reconectar suele fallar en Android; reintentamos.
  Future<void> _sendRetry(String cmd, {int tries = 5}) async {
    for (var i = 0; i < tries; i++) {
      if (await _send(cmd)) return;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _sendRawRetry(String cmd, {int tries = 5}) async {
    for (var i = 0; i < tries; i++) {
      if (await _sendRaw(cmd)) return;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  // ==================== Autenticacion de sesion (SEC-01) ====================

  // Tras conectar: si ya hay secreto guardado, autentica (NONCE); si no, reclama
  // la placa (CLAIM, trust-on-first-use).
  Future<void> _beginAuth() async {
    _sessionToken = null;
    _claimSecretHex = await _store.loadSecret();
    await Future.delayed(const Duration(milliseconds: 800));
    if (_claimSecretHex == null) {
      await _sendRawRetry("CLAIM");
    } else {
      await _sendRawRetry("NONCE");
    }
  }

  List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  String _bytesToHex(List<int> b) {
    const h = '0123456789abcdef';
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(h[(x >> 4) & 0xF]);
      sb.write(h[x & 0xF]);
    }
    return sb.toString();
  }

  // HMAC-SHA256(secretBytes, nonceBytes) en hex. Debe coincidir byte a byte con
  // el mbedtls de la placa: clave = 16 bytes del secreto, mensaje = bytes crudos
  // del nonce (decodificados del hex).
  Future<String?> _computeAuthMac(String? secretHex, String nonceHex) async {
    if (secretHex == null) return null;
    final mac = await Hmac.sha256().calculateMac(
      _hexToBytes(nonceHex),
      secretKey: SecretKey(_hexToBytes(secretHex)),
    );
    return _bytesToHex(mac.bytes);
  }

  // Recibido NONCE:<hex> -> responder AUTH:<hmac>.
  Future<void> _respondNonce(String nonceHex) async {
    final mac = await _computeAuthMac(_claimSecretHex, nonceHex);
    if (mac != null) await _sendRaw("AUTH:$mac");
  }

  // Recibido CLAIMED:<secretHex>:<id>:<name> -> guardar secreto y autenticar.
  Future<void> _onClaimed(String secretHex, String id, String name) async {
    _claimSecretHex = secretHex;
    await _store.saveSecret(secretHex);
    setState(() {
      myId = id;
      myName = name;
    });
    await _sendRawRetry("NONCE");
  }

  // SEC-02: dialogo de confirmacion del SAS. El usuario compara el codigo con el
  // que muestra la OTRA placa; si coinciden, se guarda el contacto (PAIROK);
  // si no, se aborta (PAIRNO).
  void _showSasDialog(String src, String sas, String fingerprint, String name) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Verifica el emparejamiento"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Con: $name  (${src.toUpperCase()})"),
            const SizedBox(height: 12),
            const Text(
                "Compara este codigo con el que muestra la otra placa en su pantalla:"),
            const SizedBox(height: 12),
            Center(
              child: Text(
                sas,
                style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4),
              ),
            ),
            const SizedBox(height: 12),
            Text("Huella de clave: $fingerprint",
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            const Text(
                "Solo confirma si los codigos coinciden en ambas placas.",
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _send("PAIRNO");
            },
            child: const Text("No coinciden"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _send("PAIROK");
            },
            child: const Text("Coinciden"),
          ),
        ],
      ),
    );
  }

  // ==================== Helpers de estado por mensaje ====================

  /// Busca en todos los chats la primera burbuja outgoing que contiene [id]
  /// en alguna de sus partes ([hasMsgId]).
  ChatMessage? _findByMsgId(String id) {
    for (final msgs in chats.values) {
      for (final m in msgs) {
        if (m.outgoing && m.hasMsgId(id)) return m;
      }
    }
    return null;
  }

  // ==================== Eventos desde la placa ====================
  void _onEvent(List<int> value) {
    final msg = utf8.decode(value, allowMalformed: true);
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
      // REL-03: la lista de contactos llega fragmentada (una notificacion por
      // contacto) para no truncarse por el MTU. Se acumula y se confirma al final.
      case "CONTACTS_BEGIN":
        _pendingContacts = {};
        break;
      case "CONTACT":
        final kv = rest.split('=');
        if (kv.length == 2 && kv[0].isNotEmpty) {
          _pendingContacts[kv[0]] = kv[1];
        }
        break;
      case "CONTACTS_END":
        setState(() {
          contacts
            ..clear()
            ..addAll(_pendingContacts);
        });
        break;
      case "CONTACTS":
        // Compatibilidad con firmware viejo (lista en una sola linea).
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
          final payloadStr = rest.substring(j + 1);
          // Reconstruir bytes para detectar el header de parte (0x01...0x02).
          // 0x01 y 0x02 son ASCII valido: round-trip utf8 decode/encode es sin perdida.
          final payloadBytes = utf8.encode(payloadStr);
          _handleIncoming(src, payloadBytes);
        }
        break;
      case "ERR":
        if (rest == "unclaimed") {
          // La placa perdio su dueno; reclamarla de nuevo.
          _sendRawRetry("CLAIM");
        } else if (rest == "auth") {
          // El secreto guardado no coincide (placa reclamada por otro / datos
          // borrados). Se limpia para forzar un nuevo claim en la proxima conexion.
          _store.clearSecret();
          _claimSecretHex = null;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    "No se pudo autenticar con la placa. Desvincula y volve a vincular.")));
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("Placa: $rest")));
        }
        break;

      // ── Handshake de sesion (SEC-01) ─────────────────────────────────────
      case "CLAIMED":
        // rest = "<secretHex>:<idHex>:<name>"
        final cp = rest.split(':');
        if (cp.length >= 3) {
          _onClaimed(cp[0], cp[1], cp[2]);
        }
        break;
      case "NONCE":
        // rest = "<nonceHex>" -> responder AUTH.
        if (rest.isNotEmpty) _respondNonce(rest);
        break;
      case "OK":
        // rest = "<token>" -> sesion autenticada; pedir identidad y contactos.
        setState(() => _sessionToken = rest);
        _sendRetry("WHOAMI");
        _sendRetry("LIST");
        break;

      // ── Confirmacion anti-MITM del pairing (SEC-02) ──────────────────────
      case "SASPENDING":
        // rest = "<srcHex>:<sas>:<fingerprint>:<name>"
        final sp = rest.split(':');
        if (sp.length >= 4) {
          _showSasDialog(sp[0], sp[1], sp[2], sp.sublist(3).join(':'));
        }
        break;
      case "PAIRABORT":
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Emparejamiento cancelado: el codigo no coincidia.")));
        }
        break;
      case "WIFI":
        setState(() => wifiState = rest);
        break;
      case "BATT":
        // UX-02: nivel de bateria de la placa.
        setState(() => boardBattery = int.tryParse(rest));
        break;

      // ── Feedback de entrega por mensaje ──────────────────────────────────
      case "SENT":
        // rest = "<msgIdHex>:<dstHex>[:<cid>]"
        final sent = SentEvent.parse(rest);
        if (sent != null) {
          setState(() {
            final target = sent.cid != null ? _cidMap.remove(sent.cid) : null;
            if (target != null) {
              // WR-02 fix: correlación exacta por cid → parte precisa, sin
              // importar el orden de llegada de los SENT.
              if (target.part < target.msg.partMsgIds.length) {
                target.msg.partMsgIds[target.part] = sent.msgId;
              }
            } else {
              // Fallback (firmware viejo / sin cid): forward-scan FIFO por destino.
              final msgs = chats[sent.dst];
              if (msgs != null) {
                for (var k = 0; k < msgs.length; k++) {
                  if (msgs[k].outgoing && msgs[k].assignNextMsgId(sent.msgId)) {
                    break;
                  }
                }
              }
            }
          });
        }
        break;

      case "ACK":
        // rest = "<msgIdHex>:<medio>" — medio es "lora" o "broker"
        final ackParts = rest.split(':');
        if (ackParts.length >= 2) {
          final ackId = ackParts[0].toUpperCase();
          final medio = ackParts[1].toLowerCase();
          setState(() {
            final m = _findByMsgId(ackId);
            if (m != null) {
              // Marcar la parte especifica como delivered con su medio.
              final idx = m.partMsgIds.indexOf(ackId);
              if (idx >= 0) {
                m.partStatuses[idx] = MsgStatus.delivered;
                m.partMediums[idx] =
                    (medio == 'broker') ? MsgMedium.broker : MsgMedium.lora;
              }
              // Recalcular el estado/medio agregado de la burbuja completa.
              m.status = m.aggregateStatus;
              m.medium = m.aggregateMedium;
            }
          });
        }
        break;

      case "NACK":
        // rest = "<msgIdHex>"
        if (rest.isNotEmpty) {
          setState(() {
            final nackId = rest.toUpperCase();
            final m = _findByMsgId(nackId);
            if (m != null) {
              final idx = m.partMsgIds.indexOf(nackId);
              if (idx >= 0) m.partStatuses[idx] = MsgStatus.failed;
              m.status = m.aggregateStatus;
              m.medium = m.aggregateMedium;
            }
          });
        }
        break;

      case "FAIL":
        // rest = "<msgIdHex>"
        if (rest.isNotEmpty) {
          setState(() {
            final failId = rest.toUpperCase();
            final m = _findByMsgId(failId);
            if (m != null) {
              final idx = m.partMsgIds.indexOf(failId);
              if (idx >= 0) m.partStatuses[idx] = MsgStatus.failed;
              m.status = m.aggregateStatus;
              m.medium = m.aggregateMedium;
            }
          });
        }
        break;

      case "NEEDNET":
        // rest = "<msgIdHex>" — el fallback requiere hotspot pero la placa no tiene WiFi.
        if (rest.isNotEmpty) {
          setState(() {
            final needId = rest.toUpperCase();
            final m = _findByMsgId(needId);
            if (m != null) {
              final idx = m.partMsgIds.indexOf(needId);
              if (idx >= 0) m.partStatuses[idx] = MsgStatus.failed;
              m.status = m.aggregateStatus;
              m.medium = m.aggregateMedium;
            }
          });
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  "Prende el hotspot del teléfono para entregar por broker"),
              duration: Duration(seconds: 5),
            ),
          );
        }
        break;
    }
    // UX-01: persistir tras procesar el evento (mensajes entrantes, cambios de
    // estado de entrega, contactos). Barato y fire-and-forget.
    _persistChats();
  }

  // ==================== Acciones ====================
  Future<void> _sendMessage(String contactId) async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _msgCtrl.clear();

    // Partir en chunks byte-aware; cada uno cabe en BLE MTU, buffer del firmware y LoRa.
    final chunks = Chunking.splitUtf8(text, Chunking.maxBytes);
    final n = chunks.length;

    // grp=0 para mensajes de 1 parte (backward compatible).
    // Multi-parte recibe un grp unico incremental (mod 65536) para que el receptor
    // pueda distinguir grupos de diferentes mensajes del mismo emisor.
    final grp = n > 1 ? (_grpCounter = (_grpCounter + 1) % 65536) : 0;

    // UNA sola burbuja logica con N slots: se muestra el texto completo de inmediato
    // y el estado/medio se actualiza a medida que llegan los SENT/ACK/NACK/FAIL.
    final bubble = ChatMessage(text, true, false, partIds: List.filled(n, null));
    setState(() {
      chats.putIfAbsent(contactId, () => []).add(bubble);
    });

    // Enviar cada chunk con su header de parte y un cid de correlacion unico.
    // El cid vuelve en SENT y ubica el msgId en la parte exacta (fix WR-02).
    for (var i = 0; i < n; i++) {
      final payload = Chunking.buildChunkPayload(grp, i, n, chunks[i]);
      final chunkStr = Chunking.decodeChunk(payload);
      final cid = _cidCounter++;
      _cidMap[cid] = _SentTarget(bubble, i);
      await _send('SEND:$contactId:$cid:$chunkStr');
      await Future.delayed(const Duration(milliseconds: 250)); // evitar colisiones LoRa
    }
    _persistChats();  // UX-01: guardar el mensaje saliente
  }

  // ==================== Reensamblado de mensajes entrantes ====================

  /// Procesa un mensaje entrante con posible header de parte (mensajes multi-parte).
  ///
  /// Si [payloadBytes] NO tiene header (n==1 o header malformado): decodifica y
  /// muestra directo — camino backward-compatible con mensajes cortos.
  /// Si tiene header: bufferea la parte en [_reassembly] y muestra UNA burbuja solo
  /// cuando llegan las n partes del grupo (completado en orden de llegada).
  void _handleIncoming(String src, List<int> payloadBytes) {
    final header = Chunking.parsePartHeader(payloadBytes);

    if (header == null) {
      // Mensaje de 1 parte o header malformado: mostrar directo (backward compatible).
      final text = Chunking.decodeChunk(payloadBytes);
      setState(() {
        chats.putIfAbsent(src, () => []).add(ChatMessage(text, false, false));
      });
      return;
    }

    // Mensaje multi-parte: bufferar por (src, grp).
    final key = '$src:${header.grp}';

    // Cap de 16 grupos activos para acotar memoria (T-04-02: DoS prevention).
    // Al exceder el cap, descartar el grupo mas antiguo.
    if (!_reassembly.containsKey(key) && _reassembly.length >= 16) {
      String? oldestKey;
      DateTime? oldestTime;
      _reassembly.forEach((k, v) {
        if (oldestTime == null || v.created.isBefore(oldestTime!)) {
          oldestKey = k;
          oldestTime = v.created;
        }
      });
      if (oldestKey != null) _reassembly.remove(oldestKey);
    }

    final group = _reassembly.putIfAbsent(key, () => PartGroup(header.n));
    // Descartar partes cuyo n no coincide con el grupo ya creado (protocolo corrupto).
    if (group.n != header.n) {
      debugPrint('chunking: n inconsistente en grupo $key: '
          'esperado ${group.n}, recibido ${header.n}; parte descartada');
      return;
    }
    group.addPart(header.i, header.textBytes);

    if (group.isComplete) {
      final text = group.assemble();
      _reassembly.remove(key);
      setState(() {
        chats.putIfAbsent(src, () => []).add(ChatMessage(text, false, false));
      });
    }
  }

  /// Elimina grupos de reensamblado incompletos con mas de 60 segundos de antiguedad.
  ///
  /// Llamado periodicamente por [_purgeTimer] cada 30 s.
  /// Previene leak de memoria por mensajes multi-parte que nunca se completaron.
  void _purgeExpiredGroups() {
    final now = DateTime.now();
    _reassembly.removeWhere(
      (_, group) => now.difference(group.created).inSeconds > 60,
    );
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

  void _wifiDialog() {
    final ssidCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Configurar WiFi"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: ssidCtrl,
              decoration: const InputDecoration(labelText: "SSID (nombre de red)")),
          const SizedBox(height: 12),
          TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Contraseña")),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          FilledButton(
              onPressed: () {
                final ssid = ssidCtrl.text.trim();
                if (ssid.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                if (ssid.contains(':')) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('El nombre de red no puede contener ":"'),
                  ));
                  return;
                }
                // NO se hace trim de la pass: puede contener espacios o ':' validos.
                _send("SETWIFI:$ssid:${passCtrl.text}");
                Navigator.pop(ctx);
              },
              child: const Text("Guardar")),
        ],
      ),
    );
  }

  Future<void> _unlinkBoard() async {
    _userDisconnect = true;  // REL-04: desvinculacion intencional, no reconectar
    // Avisar a la placa para que borre su bond y muestre "sin telefono".
    try {
      await _send("UNLINK");
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (_) {}
    try {
      await board?.removeBond();
    } catch (_) {}
    try {
      await board?.disconnect();
    } catch (_) {}
    await _store.clear();
    await _chatStore.clear();  // UX-01: borrar el historial persistido
    _sessionToken = null;
    _claimSecretHex = null;
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
    _purgeTimer?.cancel();
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
          if (boardBattery != null) _BatteryBadge(pct: boardBattery!),
          _WifiBadge(wifiState: wifiState),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _renameDialog();
              if (v == 'unlink') _unlinkBoard();
              if (v == 'refresh') _send("LIST");
              if (v == 'wifi') _wifiDialog();
              if (v == 'clearwifi') _send("CLEARWIFI");
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text("Renombrar mi placa")),
              PopupMenuItem(value: 'wifi', child: Text("Configurar WiFi")),
              PopupMenuItem(value: 'clearwifi', child: Text("Borrar WiFi")),
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
                          child: m.outgoing
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Flexible(
                                      child: Text(m.text,
                                          style: const TextStyle(
                                              color: Colors.white)),
                                    ),
                                    const SizedBox(width: 6),
                                    _StatusIcon(
                                        status: m.status, medium: m.medium),
                                  ],
                                )
                              : Text(m.text,
                                  style: const TextStyle(
                                      color: Color(0xFF172033))),
                        ),
                      );
                    },
                  ),
          ),
          Builder(builder: (_) {
            final len = utf8.encode(_msgCtrl.text).length;
            final parts = _msgCtrl.text.isEmpty
                ? 0
                : Chunking.splitUtf8(_msgCtrl.text, Chunking.maxBytes).length;
            final over = len > Chunking.maxBytes;
            return Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    over
                        ? "$len car. · se enviará en $parts mensajes"
                        : "$len/${Chunking.maxBytes}",
                    style: TextStyle(
                      fontSize: 11,
                      color: over ? const Color(0xFFB45309) : Colors.grey.shade500,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      minLines: 1,
                      maxLines: 4,
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
              ]),
            );
          }),
        ]),
      ),
    );
  }
}

/// Ícono de estado de entrega para burbujas salientes.
/// Sigue el mismo patrón de mapeo estado→icono+color que [_WifiBadge].
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.medium});
  final MsgStatus status;
  final MsgMedium medium;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;

    switch (status) {
      case MsgStatus.sending:
        icon = Icons.schedule;
        color = Colors.white54;
        break;
      case MsgStatus.delivered:
        icon = medium == MsgMedium.broker ? Icons.cloud_done : Icons.check;
        color = Colors.white;
        break;
      case MsgStatus.failed:
        icon = Icons.error_outline;
        color = const Color(0xFFFFCDD2); // rojo claro sobre fondo azul
        break;
    }

    return Icon(icon, size: 14, color: color);
  }
}

/// Badge compacto del estado WiFi de la placa, mostrado en el AppBar.
/// Mapea los codigos del firmware a icono + tooltip legibles.
class _WifiBadge extends StatelessWidget {
  const _WifiBadge({required this.wifiState});
  final String wifiState;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    final String tooltip;

    switch (wifiState) {
      case "conectado":
        icon = Icons.wifi;
        color = const Color(0xFF2563EB);
        tooltip = "WiFi conectado";
        break;
      case "sin_red":
        icon = Icons.wifi_off;
        color = const Color(0xFFDC2626); // rojo
        tooltip = "Sin red WiFi";
        break;
      case "SET":
        icon = Icons.wifi_find;
        color = const Color(0xFFD97706); // ambar — transitorio
        tooltip = "Conectando...";
        break;
      case "sin_cred":
      default:
        icon = Icons.wifi_find;
        color = Colors.grey;
        tooltip = wifiState.isEmpty ? "WiFi sin configurar" : "WiFi: $wifiState";
    }

    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}

/// Badge de batería de la placa en el AppBar (UX-02).
class _BatteryBadge extends StatelessWidget {
  const _BatteryBadge({required this.pct});
  final int pct;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    if (pct >= 80) {
      icon = Icons.battery_full;
    } else if (pct >= 50) {
      icon = Icons.battery_5_bar;
    } else if (pct >= 20) {
      icon = Icons.battery_3_bar;
    } else {
      icon = Icons.battery_alert;
    }
    final color = pct < 20 ? const Color(0xFFDC2626) : Colors.grey.shade700;
    return Tooltip(
      message: "Batería de la placa: $pct%",
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 20),
          Text("$pct%", style: TextStyle(fontSize: 11, color: color)),
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
