import 'package:mssql_native/mssql_native.dart';

import '../models/server_profile.dart';

class SqlTable {
  const SqlTable(this.schema, this.name);
  final String schema;
  final String name;

  String get fullName => '${quoteIdentifier(schema)}.${quoteIdentifier(name)}';
}

String quoteIdentifier(String name) => '[${name.replaceAll(']', ']]')}]';

class SqlManager {
  final Map<String, MssqlConnection> _sessions = {};

  String _key(ServerProfile server, String database) =>
      '${server.id}\u0001$database';

  Future<MssqlConnection> open(
    ServerProfile server,
    String database,
    String password,
  ) async {
    final key = _key(server, database);
    final old = _sessions[key];
    if (old != null && !old.isClosed) return old;
    final connection = await MssqlConnection.connect(
      host: server.host,
      port: server.port,
      database: database,
      username: server.username,
      password: password,
      applicationName: 'OdinSQL',
    );
    _sessions[key] = connection;
    return connection;
  }

  Future<List<String>> databases(ServerProfile server, String password) async {
    final connection = await open(server, server.startDatabase, password);
    final rows = await connection.queryRows(
      'SELECT [name] FROM sys.databases '
      'WHERE [state] = 0 AND HAS_DBACCESS([name]) = 1 ORDER BY [name]',
    );
    return rows.map((row) => row['name'].toString()).toList();
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

  Future<MssqlExecutionResult> query(
    ServerProfile server,
    String database,
    String password,
    String sql,
  ) async {
    final connection = await open(server, database, password);
    // The driver returns every result set, and handles both read and write
    // statements without unsafe SQL verb guessing.
    return connection.query(
      sql,
      maximumRows: 10000,
      maximumBytes: 32 * 1024 * 1024,
    );
  }

  Future<void> closeServer(ServerProfile server) async {
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
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final connection in sessions) {
      if (!connection.isClosed) await connection.close();
    }
  }
}
