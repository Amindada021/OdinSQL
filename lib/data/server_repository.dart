import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_profile.dart';

class ServerRepository {
  static const _profilesKey = 'odin_sql_profiles_v1';
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  Future<void> _pending = Future<void>.value();

  Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }
  Future<List<ServerProfile>> _read() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_profilesKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((item) =>
      ServerProfile.fromJson(item as Map<String, dynamic>)).toList();
  }
  Future<List<ServerProfile>> list() async { await _pending; return _read(); }
  Future<void> _write(List<ServerProfile> profiles) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(_profilesKey, jsonEncode(profiles.map((p) => p.toJson()).toList()));
    if (!saved) throw StateError('Could not save server profiles.');
  }
  Future<void> save(ServerProfile profile, {String? password}) => _serialize(() async {
    final profiles = await _read();
    final index = profiles.indexWhere((item) => item.id == profile.id);
    if (index >= 0) { profiles[index] = profile; } else { profiles.add(profile); }
    if (password != null && password.isNotEmpty) {
      await _secure.write(key: 'sql_password_${profile.id}', value: password);
    }
    await _write(profiles);
  });
  Future<String?> passwordFor(ServerProfile profile) => _secure.read(key: 'sql_password_${profile.id}');
  Future<void> remove(ServerProfile profile) => _serialize(() async {
    final profiles = await _read();
    profiles.removeWhere((item) => item.id == profile.id);
    await _write(profiles);
    await _secure.delete(key: 'sql_password_${profile.id}');
  });
}
