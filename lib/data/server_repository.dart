import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_profile.dart';

class ServerRepository {
  static const _profilesKey = 'odin_sql_profiles_v1';
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  Future<List<ServerProfile>> list() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_profilesKey);
    if (raw == null) return [];
    final items = jsonDecode(raw) as List<dynamic>;
    return items
        .map((item) => ServerProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(ServerProfile profile, {String? password}) async {
    final profiles = await list();
    final index = profiles.indexWhere((item) => item.id == profile.id);
    if (index >= 0) {
      profiles[index] = profile;
    } else {
      profiles.add(profile);
    }
    if (password != null && password.isNotEmpty) {
      await _secure.write(key: 'sql_password_${profile.id}', value: password);
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _profilesKey,
      jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
  }

  Future<String?> passwordFor(ServerProfile profile) =>
      _secure.read(key: 'sql_password_${profile.id}');

  Future<void> remove(ServerProfile profile) async {
    final profiles = await list();
    profiles.removeWhere((item) => item.id == profile.id);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _profilesKey,
      jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
    await _secure.delete(key: 'sql_password_${profile.id}');
  }
}
