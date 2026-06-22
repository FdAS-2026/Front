import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Una placa enlazada (recordada) con este telefono.
class LinkedBoard {
  const LinkedBoard(this.id, this.name);
  final String id; // remoteId BLE
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory LinkedBoard.fromJson(Map<String, dynamic> j) =>
      LinkedBoard(j['id'] as String, (j['name'] as String?) ?? '');
}

/// Persiste la lista de placas enlazadas en `shared_preferences`, para que el
/// telefono las recuerde entre sesiones.
class LinkedBoardsStore {
  static const String _key = 'linked_boards';

  Future<List<LinkedBoard>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List)
        .map((e) => LinkedBoard.fromJson(e as Map<String, dynamic>))
        .toList();
    return list;
  }

  Future<void> _save(List<LinkedBoard> boards) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(boards.map((b) => b.toJson()).toList()),
    );
  }

  Future<void> add(String id, String name) async {
    final boards = await load();
    if (boards.any((b) => b.id == id)) {
      // Actualiza el nombre si cambia.
      final updated = boards
          .map((b) => b.id == id ? LinkedBoard(id, name) : b)
          .toList();
      await _save(updated);
      return;
    }
    boards.add(LinkedBoard(id, name));
    await _save(boards);
  }

  Future<void> remove(String id) async {
    final boards = await load();
    boards.removeWhere((b) => b.id == id);
    await _save(boards);
  }

  Future<bool> isLinked(String id) async {
    final boards = await load();
    return boards.any((b) => b.id == id);
  }
}
