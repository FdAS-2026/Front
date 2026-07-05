import 'dart:convert';

/// Logica pura de fragmentacion y reensamblado de mensajes UTF-8 byte-aware.
///
/// Sin dependencias de Flutter ni BLE: testeable con `flutter test` sin hardware.
/// Solo metodos static sobre una clase sellada y una clase auxiliar [PartGroup]
/// sin estado de instancia global.
///
/// Bytes de control elegidos:
///   [kPartStart] = 0x01 (ASCII STX)
///   [kPartEnd]   = 0x02 (ASCII ETX)
/// Si el stack BLE filtra esos bytes en el notify value, cambiar ambas constantes
/// a 0x7E ('~') y 0x7C ('|') respectivamente; el resto del codigo no cambia.
class Chunking {
  /// Byte de inicio del header de parte (STX = 0x01).
  /// Cambiar a 0x7E si el stack BLE filtra bytes de control.
  static const int kPartStart = 0x01;

  /// Byte de fin del header de parte (ETX = 0x02).
  /// Cambiar a 0x7C si el stack BLE filtra bytes de control.
  static const int kPartEnd = 0x02;

  /// Tamaño maximo en bytes UTF-8 por chunk.
  ///
  /// Con este valor el plaintext completo (chunk + header de 12 B maximo) cabe
  /// holgadamente en BLE MTU (~170 B), el buffer clear[256] del firmware y el
  /// payload LoRa (~255 B). Ajustar con cuidado: verificar que maxBytes + 12 <= 255.
  static const int maxBytes = 100;

  /// Parte [text] en trozos cuyo utf8.encode tiene longitud <= [maxBytes],
  /// cortando siempre en borde de codepoint UTF-8.
  ///
  /// Nunca corta a mitad de un codepoint multi-byte: retrocede el punto de corte
  /// mientras el byte en esa posicion sea un continuation byte (b & 0xC0 == 0x80).
  /// Soporta acentos (2 bytes), ideogramas (3 bytes) y emoji (4 bytes).
  ///
  /// Devuelve lista vacia si [text] esta vacio.
  static List<List<int>> splitUtf8(String text, int maxBytes) {
    final bytes = utf8.encode(text);
    if (bytes.isEmpty) return [];
    final chunks = <List<int>>[];
    var start = 0;
    while (start < bytes.length) {
      var end = (start + maxBytes).clamp(0, bytes.length);
      // Retroceder al borde del codepoint: omitir continuation bytes (0x80–0xBF).
      while (end > start &&
          end < bytes.length &&
          (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      // Guard: si maxBytes es menor que el codepoint completo (p.ej. emoji 4B con
      // maxBytes=3), end retrocede hasta start y el loop se congela. Forzar avance
      // de 1 byte; allowMalformed:true en decode absorbe el codepoint partido.
      // Precondicion recomendada: maxBytes >= 4 para no partir codepoints.
      if (end == start) end = (start + 1).clamp(0, bytes.length);
      chunks.add(bytes.sublist(start, end));
      start = end;
    }
    return chunks;
  }

  /// Construye el header de parte como bytes:
  /// [kPartStart] + utf8('<grp>:<i>:<n>') + [kPartEnd].
  ///
  /// Tamaño worst-case: 1 + 5 + 1 + 2 + 1 + 2 + 1 = 13 bytes
  /// (grp=65535, i=99, n=99). Tipico: 8–9 bytes.
  static List<int> buildPartHeader(int grp, int i, int n) {
    final inner = '$grp:$i:$n';
    return [kPartStart, ...utf8.encode(inner), kPartEnd];
  }

  /// Arma el payload completo (plaintext que entra al cifrado E2E).
  ///
  /// Si [n] == 1: devuelve [chunkBytes] sin header (backward compatible con
  /// mensajes cortos de una sola parte).
  /// Si [n] > 1: antepone [buildPartHeader(grp, i, n)] a [chunkBytes].
  static List<int> buildChunkPayload(
      int grp, int i, int n, List<int> chunkBytes) {
    if (n == 1) return chunkBytes;
    return [...buildPartHeader(grp, i, n), ...chunkBytes];
  }

  /// Parsea el payload descifrado para extraer el header de parte.
  ///
  /// Devuelve un record con (grp, i, n, textBytes) si el payload tiene un header
  /// valido. Devuelve null si:
  ///   - [payload] esta vacio
  ///   - El primer byte no es [kPartStart]
  ///   - No se encuentra [kPartEnd] en el payload
  ///   - Alguno de los tres campos (grp, i, n) no es un entero valido
  ///
  /// Es robusto ante bytes corruptos en transito (usa allowMalformed:true).
  static ({int grp, int i, int n, List<int> textBytes})? parsePartHeader(
      List<int> payload) {
    if (payload.isEmpty || payload[0] != kPartStart) return null;
    final etx = payload.indexOf(kPartEnd);
    if (etx < 0) return null; // ETX no encontrado: header malformado
    final inner =
        utf8.decode(payload.sublist(1, etx), allowMalformed: true);
    final parts = inner.split(':');
    if (parts.length != 3) return null;
    final grp = int.tryParse(parts[0]);
    final i = int.tryParse(parts[1]);
    final n = int.tryParse(parts[2]);
    if (grp == null || i == null || n == null) return null;
    // Validar rangos: n debe ser >= 1 e i debe estar en [0, n).
    if (n < 1 || i < 0 || i >= n) return null;
    return (grp: grp, i: i, n: n, textBytes: payload.sublist(etx + 1));
  }

  /// Decodifica bytes UTF-8 a String, tolerando bytes corruptos en transito.
  static String decodeChunk(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);
}

/// Buffer de reensamblado para un mensaje multi-parte.
///
/// Clase pura sin dependencias de Flutter ni BLE.
/// Uso tipico: crear un [PartGroup] al recibir la primera parte de un grupo,
/// llamar [addPart] por cada parte recibida y consultar [isComplete] antes de
/// llamar [assemble].
///
/// El campo [created] permite a la capa superior implementar un timeout:
///   now.difference(group.created).inSeconds > 60 -> descartar grupo.
class PartGroup {
  /// Numero total de partes esperadas.
  final int n;

  /// Partes indexadas por i; null indica que aun no se recibio esa parte.
  final List<List<int>?> parts;

  /// Cantidad de partes distintas recibidas hasta el momento.
  int received = 0;

  /// Marca de tiempo de creacion del grupo (referencia para timeout externo).
  final DateTime created;

  PartGroup(this.n)
      : assert(n >= 1, 'PartGroup: n debe ser >= 1'),
        parts = List.filled(n, null),
        created = DateTime.now();

  /// Registra la parte con indice [i] y contenido [bytes].
  ///
  /// Ignora la llamada si:
  ///   - [i] esta fuera del rango [0, n)
  ///   - Ya se habia recibido una parte con el mismo [i] (evita duplicados y
  ///     protege contra inyeccion de datos en un slot ya ocupado)
  void addPart(int i, List<int> bytes) {
    if (i < 0 || i >= n) return;
    if (parts[i] != null) return; // duplicado: ignorar sin incrementar received
    parts[i] = bytes;
    received++;
  }

  /// true si se han recibido todas las [n] partes.
  bool get isComplete => received == n;

  /// Reensambla el mensaje concatenando las partes en orden por indice i.
  ///
  /// Usa allowMalformed:true para no lanzar ante bytes corruptos en transito
  /// (el receptor muestra U+FFFD en lugar de crashear).
  String assemble() {
    assert(isComplete, 'assemble() llamado antes de recibir todas las partes');
    final allBytes =
        parts.expand((b) => b ?? const <int>[]).toList();
    return utf8.decode(allBytes, allowMalformed: true);
  }
}
