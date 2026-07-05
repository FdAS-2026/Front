import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persiste el historial de chat por contacto (UX-01).
///
/// Trabaja sobre la forma serializada (`Map<contactId, List<mensajeJson>>`) para
/// no depender del widget: la conversión a/desde ChatMessage la hace la UI. El
/// encode/decode es puro y testeable sin `SharedPreferences`.
class ChatStore {
  static const String _key = 'chat_history';

  /// Serializa el historial a JSON. Puro (testeable sin plataforma).
  static String encode(Map<String, List<Map<String, dynamic>>> data) =>
      jsonEncode(data);

  /// Reconstruye el historial desde JSON. Tolera datos corruptos → {}.
  static Map<String, List<Map<String, dynamic>>> decode(String raw) {
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (k, v) => MapEntry(
          k,
          (v as List)
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList(),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Map<String, List<Map<String, dynamic>>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, encode(data));
  }

  Future<Map<String, List<Map<String, dynamic>>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(_key) ?? '');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
