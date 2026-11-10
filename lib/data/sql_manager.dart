import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import '../ui/app_settings.dart';

import '../models/server_profile.dart';

class SqlObject extends SqlTable {
  const SqlObject(super.schema, super.name, this.type);
  final String type;
}

class SqlTable {
  const SqlTable(this.schema, this.name);
  final String schema;
  final String name;

  String get fullName => '${quoteIdentifier(schema)}.${quoteIdentifier(name)}';
}

String quoteIdentifier(String name) => '[${name.replaceAll(']', ']]')}]';

class SqlManager {
  /// Diagnose the TCP port from the phone, only after a failed SQL login.
  /// A reachable TCP socket does not prove that SQL/TDS/TLS will succeed.
  Future<String> explainConnectionFailure(ServerProfile server, Object failure) async {
    if (failure is! MssqlConnectionException ||
        failure.type != MssqlErrorType.connection) {
      return failure.toString();
    }

    final endpoint = '${server.host}:${server.port}';
    Socket? probe;
    try {
      probe = await Socket.connect(server.host, server.port,
          timeout: const Duration(seconds: 5));
      return tr(
        'اتصال TCP به $endpoint برقرار می‌شود، اما ورود به SQL Server ناموفق است. '
        'در SSMS با TCP و همین پورت تست کنید. نسخه SQL Server و تنظیمات TLS/Force Encryption '
        'را بررسی کنید. راهنمای TLS 1.0 در متن خطای 20002 فقط یک احتمال است.\n\n$failure',
        'TCP connection to $endpoint succeeds, but the SQL Server login/handshake fails. '
        'Test SSMS with TCP on exactly this port and inspect SQL Server version, TLS '
        'and Force Encryption settings. The legacy TLS hint in error 20002 is only '
        'one possible cause.\n\n$failure',
      );
    } catch (networkError) {
      return tr(
        'پورت TCP $endpoint از این گوشی قابل دسترس نیست. IP، پورت واقعی SQL Server، '
        'TCP/IP، فایروال و مسیر شبکه یا VPN را بررسی کنید. '
        'اتصال SSMS از یک کامپیوتر دیگر لزوماً دسترسی گوشی را ثابت نمی‌کند.\n'
        'جزئیات: $networkError',
        'TCP port $endpoint is not reachable from this phone. Verify the IP, '
        'actual SQL Server TCP port, SQL Server TCP/IP, firewall and phone network/VPN. '
        'SSMS on a different PC does not prove phone connectivity.\n'
        'Details: $networkError',
      );
    } finally {
      probe?.destroy();
    }
  }

  final Map<String, MssqlConnection> _sessions = {};
  final Map<String, Future<MssqlConnection>> _opening = {};

  bool isConnected(ServerProfile server) => _sessions.entries.any(
    (entry) => entry.key.startsWith('${server.id}\u0001') && !entry.value.isClosed,
  );

  String _key(ServerProfile server, String database) =>
      '${server.id}\u0001$database';

  Future<MssqlConnection> open(
    ServerProfile server,
    String database,
    String password, {
    String? sessionId,
  }) async {
    final key = sessionId == null ? _key(server, database) : '${server.id}\u0001query\u0001$sessionId';
    final old = _sessions[key];
    if (old != null && !old.isClosed) return old;
    final pending = _opening[key];
    if (pending != null) return pending;
    final future = MssqlConnection.connect(
      host: server.host, port: server.port, database: database,
      username: server.username, password: password, applicationName: 'OdinSQL',
    );
    _opening[key] = future;
    try {
      final connection = await future;
      _sessions[key] = connection;
      return connection;
    } finally { _opening.remove(key); }
  }

  Future<List<String>> databases(ServerProfile server, String password) async {
    final connection = await open(server, server.startDatabase, password);
    final rows = await connection.queryRows(
      'SELECT [name] FROM sys.databases '
      'WHERE [state] = 0 AND HAS_DBACCESS([name]) = 1 ORDER BY [name]',
    );
    return rows.map((row) => row['name'].toString()).toList();
  }

  Future<Map<String, Object?>> serverInfo(ServerProfile server, String password) async {
    final connection = await open(server, server.startDatabase, password);
    final rows = await connection.queryRows(
      "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)) AS ServerName, "
      "CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion, "
      "CAST(SERVERPROPERTY('Edition') AS nvarchar(256)) AS Edition, "
      "CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS ProductLevel, "
      "@@SPID AS SessionId, SUSER_SNAME() AS LoginName, DB_NAME() AS CurrentDatabase, @@VERSION AS VersionInfo",
    );
    return rows.first;
  }

  Future<List<SqlTable>> tables(
    ServerProfile server,
    String database,
    String password,
  ) async {
    final connection = await open(server, database, password);
    final rows = await connection.queryRows(
      "SELECT TABLE_SCHEMA AS schema_name, TABLE_NAME AS table_name "
      "FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' "
      "ORDER BY TABLE_SCHEMA, TABLE_NAME",
    );
    return rows
        .map((row) => SqlTable(
              row['schema_name'].toString(),
              row['table_name'].toString(),
            ))
        .toList();
  }

  Future<List<Map<String, Object?>>> columns(
    ServerProfile server,
    String database,
    String password,
    SqlTable table,
  ) async {
    final connection = await open(server, database, password);
    return connection.queryRows(
      'SELECT COLUMN_NAME AS column_name, DATA_TYPE AS data_type, '
      'IS_NULLABLE AS nullable FROM INFORMATION_SCHEMA.COLUMNS '
      'WHERE TABLE_SCHEMA = @schema AND TABLE_NAME = @table '
      'ORDER BY ORDINAL_POSITION',
      parameters: {'schema': table.schema, 'table': table.name},
    );
  }

  Future<List<SqlObject>> objects(ServerProfile server, String database, String password, String kind) async {
    const types = {'tables': "'U'", 'views': "'V'", 'procedures': "'P','PC'", 'functions': "'FN','IF','TF','FS','FT'"};
    final typeFilter = types[kind];
    if (typeFilter == null) throw ArgumentError('Unknown object category');
    final c = await open(server, database, password);
    final rows = await c.queryRows(
      'SELECT s.name AS schema_name, o.name, o.type FROM sys.objects o '
      'JOIN sys.schemas s ON s.schema_id=o.schema_id '
      'WHERE o.is_ms_shipped=0 AND o.type IN ($typeFilter) ORDER BY s.name,o.name');
    return rows.map((r) => SqlObject('${r['schema_name']}', '${r['name']}', '${r['type']}')).toList();
  }

  Future<List<Map<String, Object?>>> objectDetails(ServerProfile server, String database,
    String password, SqlObject object, String kind) async {
    final c = await open(server, database, password);
    const queries = {
      'Columns': "SELECT c.name, t.name AS type, c.max_length AS bytes, c.precision, c.scale, "
        "c.is_nullable AS nullable, c.is_identity AS identity_column, c.is_computed AS computed, dc.definition AS default_value "
        "FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id "
        "LEFT JOIN sys.default_constraints dc ON dc.object_id=c.default_object_id "
        "WHERE c.object_id=OBJECT_ID(@object) ORDER BY c.column_id",
      'Keys': "SELECT k.name, k.type_desc AS type, c.name AS column_name FROM sys.key_constraints k "
        "JOIN sys.index_columns ic ON ic.object_id=k.parent_object_id AND ic.index_id=k.unique_index_id "
        "JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id "
        "WHERE k.parent_object_id=OBJECT_ID(@object) "
        "UNION ALL SELECT fk.name, 'FOREIGN_KEY', pc.name + ' -> ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.referenced_object_id)) + '.' + "
        "QUOTENAME(OBJECT_NAME(fk.referenced_object_id)) + '.' + QUOTENAME(rc.name) "
        "FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id=fk.object_id "
        "JOIN sys.columns pc ON pc.object_id=fkc.parent_object_id AND pc.column_id=fkc.parent_column_id "
        "JOIN sys.columns rc ON rc.object_id=fkc.referenced_object_id AND rc.column_id=fkc.referenced_column_id "
        "WHERE fk.parent_object_id=OBJECT_ID(@object)",
      'Indexes': "SELECT i.name, i.type_desc AS type, i.is_unique AS unique_index, c.name AS column_name, "
        "ic.is_included_column AS included, ic.is_descending_key AS descending_key, i.filter_definition AS filter_definition "
        "FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id "
        "JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id "
        "WHERE i.object_id=OBJECT_ID(@object) AND i.index_id>0 ORDER BY i.index_id,ic.key_ordinal,ic.index_column_id",
    };
    final statement = queries[kind];
    if (statement == null) throw ArgumentError('Unknown detail category');
    return c.queryRows(statement, parameters: {'object': object.fullName});
  }

  Future<String> scriptObject(ServerProfile server, String database, String password,
    SqlObject object, String action) async {
    final c = await open(server, database, password);
    if (action == 'definition') {
      final rows = await c.queryRows('SELECT OBJECT_DEFINITION(OBJECT_ID(@object)) AS definition',
        parameters: {'object': object.fullName});
      final definition = rows.firstOrNull?['definition'];
      if (definition == null) throw StateError('Definition unavailable: encrypted object or VIEW DEFINITION permission required.');
      return definition.toString();
    }
    final rows = await c.queryRows(
      'SELECT name FROM sys.columns WHERE object_id=OBJECT_ID(@object) '
      'AND is_identity=0 AND is_computed=0 AND system_type_id<>189 ORDER BY column_id',
      parameters: {'object': object.fullName});
    final columns = rows.map((r) => quoteIdentifier('${r['name']}')).toList();
    switch (action) {
      case 'INSERT':
        if (columns.isEmpty) return 'INSERT INTO ${object.fullName} DEFAULT VALUES;';
        return 'INSERT INTO ${object.fullName} (\n  ${columns.join(',\n  ')}\n)\nVALUES (\n  ${columns.map((c) => 'NULL /* $c */').join(',\n  ')}\n);';
      case 'UPDATE':
        if (columns.isEmpty) throw StateError('No writable columns.');
        return 'UPDATE ${object.fullName}\nSET ${columns.map((c) => '$c = NULL').join(',\n    ')}\nWHERE 1 = 0; -- Replace with your filter';
      case 'DELETE': return 'DELETE FROM ${object.fullName}\nWHERE 1 = 0; -- Replace with your filter';
      default: throw ArgumentError('Unknown script action');
    }
  }

  Future<MssqlExecutionResult> query(
    ServerProfile server,
    String database,
    String password,
    String sql, {
    required String sessionId,
    required MssqlCancellationToken cancellationToken,
    required void Function(String) onDatabaseChanged,
  }) async {
    final connection = await open(server, database, password, sessionId: sessionId);
    // Keep the dropdown authoritative, including after raw USE statements or errors.
    // One persistent session per tab also preserves temp tables and explicit transactions.
    await connection.useDatabase(quoteIdentifier(database), cancellationToken: cancellationToken);
    try {
      return await connection.query(
        sql, timeout: Duration(seconds: appSettings.timeoutSeconds),
        cancellationToken: cancellationToken, retry: MssqlRetryPolicy.never,
        maximumRows: 10000, maximumBytes: 32 * 1024 * 1024,
      );
    } finally {
      if (!connection.isClosed) {
        try {
          final actual = await connection.queryScalar<String>('SELECT DB_NAME()', timeout: const Duration(seconds: 5));
          onDatabaseChanged(actual);
        } catch (_) {
          // Preserve the original outcome. The next run explicitly selects its database.
        }
      }
    }
  }

  Future<void> closeQuerySession(String sessionId) async {
    final suffix = '\u0001$sessionId';
    for (final key in _opening.keys.where((k) => k.endsWith(suffix)).toList()) {
      try { await _opening[key]; } catch (_) {}
    }
    for (final key in _sessions.keys.where((k) => k.endsWith(suffix)).toList()) {
      final c = _sessions.remove(key);
      if (c != null && !c.isClosed) await c.close();
    }
  }

  Future<void> closeServer(ServerProfile server) async {
    for (final key in _opening.keys.where((k) => k.startsWith('${server.id}\u0001')).toList()) {
      try { await _opening[key]; } catch (_) {}
    }
    final keys = _sessions.keys
        .where((key) => key.startsWith('${server.id}\u0001'))
        .toList();
    for (final key in keys) {
      final connection = _sessions.remove(key);
      if (connection != null && !connection.isClosed) {
        await connection.close();
      }
    }
  }

  Future<void> closeAll() async {
    for (final pending in _opening.values.toList()) {
      try { await pending; } catch (_) {}
    }
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final connection in sessions) {
      if (!connection.isClosed) await connection.close();
    }
  }
}

