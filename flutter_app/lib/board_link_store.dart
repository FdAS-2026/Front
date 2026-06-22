import 'package:shared_preferences/shared_preferences.dart';

/// Recuerda la placa propia (su remoteId BLE): el telefono se vincula a UNA
/// sola placa que es su identidad.
class BoardLinkStore {
  static const String _key = 'my_board';

  Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> save(String remoteId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, remoteId);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
