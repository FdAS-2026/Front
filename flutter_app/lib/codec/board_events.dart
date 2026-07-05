/// Parsing puro de los eventos que la placa manda por BLE (tag:rest).
///
/// Sin dependencias de Flutter ni BLE: testeable con `flutter test` sin hardware.
/// Extraer esta lógica (QUAL-02) permite verificar por unidad la correlación de
/// SENT/ACK que era la raíz de WR-02, sin instanciar el widget.
library;

/// Un evento crudo separado en su tag y el resto.
class BoardEvent {
  final String tag;
  final String rest;
  const BoardEvent(this.tag, this.rest);

  factory BoardEvent.parse(String raw) {
    final i = raw.indexOf(':');
    if (i < 0) return BoardEvent(raw, '');
    return BoardEvent(raw.substring(0, i), raw.substring(i + 1));
  }
}

/// Evento SENT: `<msgIdHex>:<dstHex>[:<cid>]`.
/// El `cid` (id de correlación del cliente) es la clave del fix de WR-02: permite
/// asignar el msgId a la parte EXACTA que se envió, sin depender del orden de
/// llegada de los SENT. Es null en el formato viejo (sin cid).
class SentEvent {
  final String msgId; // mayúsculas
  final String dst; // mayúsculas
  final int? cid;

  const SentEvent(this.msgId, this.dst, this.cid);

  /// Parsea el `rest` de un evento SENT. Devuelve null si no hay al menos
  /// msgId y dst.
  static SentEvent? parse(String rest) {
    final p = rest.split(':');
    if (p.length < 2 || p[0].isEmpty) return null;
    final cid = p.length > 2 ? int.tryParse(p[2]) : null;
    return SentEvent(p[0].toUpperCase(), p[1].toUpperCase(), cid);
  }
}

/// Evento ACK: `<msgIdHex>:<medio>` con medio "lora" o "broker".
class AckEvent {
  final String msgId; // mayúsculas
  final bool viaBroker;

  const AckEvent(this.msgId, this.viaBroker);

  static AckEvent? parse(String rest) {
    final p = rest.split(':');
    if (p.length < 2 || p[0].isEmpty) return null;
    return AckEvent(p[0].toUpperCase(), p[1].toLowerCase() == 'broker');
  }
}

/// Entrada de contacto `CONTACT:<idHex>=<nombre>`.
class ContactEntry {
  final String id;
  final String name;

  const ContactEntry(this.id, this.name);

  /// Parsea el `rest` de un evento CONTACT (`<idHex>=<nombre>`). El nombre puede
  /// contener '='; solo el primero separa. Devuelve null si falta el id.
  static ContactEntry? parse(String rest) {
    final i = rest.indexOf('=');
    if (i <= 0) return null;
    return ContactEntry(rest.substring(0, i), rest.substring(i + 1));
  }
}
