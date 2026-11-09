class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.startDatabase,
    required this.colorValue,
    this.imageBase64,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String startDatabase;
  final int colorValue;
  final String? imageBase64;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'startDatabase': startDatabase,
        'colorValue': colorValue,
        'imageBase64': imageBase64,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        username: json['username'] as String,
        startDatabase: json['startDatabase'] as String? ?? 'master',
        colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFF3867D6,
        imageBase64: json['imageBase64'] as String?,
      );
}
