import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// SQL text may contain sensitive literals; keep it in the same device vault as credentials.
class QueryRepository {
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  Future<void> _pending = Future<void>.value();
  Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }
  Future<Map<String, dynamic>> workspace() async {
    final raw = await _secure.read(key: 'odin_workspace_v1');
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }
  Future<void> saveWorkspace(Map<String, Object?> value) {
    final snapshot = jsonEncode(value);
    return _serialize(() => _secure.write(key: 'odin_workspace_v1', value: snapshot));
  }
  Future<List<Map<String, dynamic>>> entries(bool saved) async {
    final raw = await _secure.read(key: saved ? 'odin_saved_v1' : 'odin_history_v1');
    return raw == null ? [] : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }
  Future<void> add(Map<String, Object?> entry, {required bool saved}) => _serialize(() async {
    final items = await entries(saved);
    items.insert(0, Map<String, dynamic>.from(entry));
    if (!saved && items.length > 100) items.removeRange(100, items.length);
    await _secure.write(key: saved ? 'odin_saved_v1' : 'odin_history_v1', value: jsonEncode(items));
  });
  Future<void> remove(String id, {required bool saved}) => _serialize(() async {
    final items = (await entries(saved))..removeWhere((e) => e['id'] == id);
    await _secure.write(key: saved ? 'odin_saved_v1' : 'odin_history_v1', value: jsonEncode(items));
  });
}
