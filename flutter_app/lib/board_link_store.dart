import 'package:shared_preferences/shared_preferences.dart';

/// Recuerda la placa propia (su remoteId BLE): el telefono se vincula a UNA
/// sola placa que es su identidad. Tambien guarda el secreto de claim (SEC-01),
/// el material con el que el telefono dueno responde el desafio de sesion.
class BoardLinkStore {
  static const String _key = 'my_board';
  static const String _secretKey = 'my_board_secret';

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
    await prefs.remove(_secretKey);
  }

  /// Secreto de claim en hex (32 chars = 16 bytes). null si la placa aun no fue
  /// reclamada por este telefono.
  Future<String?> loadSecret() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_secretKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> saveSecret(String secretHex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_secretKey, secretHex);
  }

  Future<void> clearSecret() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_secretKey);
  }
}
