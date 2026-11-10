import 'package:flutter/material.dart';
import '../data/sql_manager.dart';
import '../models/server_profile.dart';
import 'app_settings.dart';

class ObjectExplorer extends StatefulWidget {
  const ObjectExplorer({super.key, required this.server, required this.database,
    required this.databases, required this.manager, required this.password,
    required this.onDatabase, required this.onQuery, required this.onRefresh});
  final ServerProfile server;
  final String database;
  final List<String> databases;
  final SqlManager manager;
  final Future<String> Function() password;
  final ValueChanged<String> onDatabase, onQuery;
  final VoidCallback onRefresh;
  @override
  State<ObjectExplorer> createState() => _ObjectExplorerState();
}

class _ObjectExplorerState extends State<ObjectExplorer> {
  String search = '';
  final Set<String> expandedKinds = {'tables'};
  final Set<String> expandedDetails = {};
  final Map<String, Future<List<SqlObject>>> objects = {};
  final Map<String, Future<List<Map<String, Object?>>>> details = {};
  Future<List<SqlObject>> load(String kind) => objects.putIfAbsent(kind, () async =>
    widget.manager.objects(widget.server, widget.database, await widget.password(), kind));
  Future<List<Map<String, Object?>>> detail(SqlObject object, String kind) =>
    details.putIfAbsent('${object.fullName}/$kind', () async => widget.manager.objectDetails(
      widget.server, widget.database, await widget.password(), object, kind));

  Future<void> script(SqlObject object, String action) async {
    try {
      final value = await widget.manager.scriptObject(widget.server, widget.database,
        await widget.password(), object, action);
      if (mounted) widget.onQuery(value);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget detailNode(SqlObject object, String kind, IconData icon) => ExpansionTile(
    key: ValueKey('${widget.database}/${object.fullName}/$kind'),
    leading: Icon(icon, size: 19), title: Text(kind),
    onExpansionChanged: (open) => setState(() {
      final key = '${object.fullName}/$kind';
      if (open) { expandedDetails.add(key); } else { expandedDetails.remove(key); }
    }),
    children: [if (expandedDetails.contains('${object.fullName}/$kind')) FutureBuilder<List<Map<String, Object?>>>(future: detail(object, kind), builder: (context, state) {
      if (state.hasError) return Padding(padding: const EdgeInsets.all(12), child: SelectableText('${state.error}'));
      if (!state.hasData) return const LinearProgressIndicator();
      if (state.data!.isEmpty) return ListTile(title: Text(tr('موردی وجود ندارد', 'No items')));
      return Column(children: [for (final row in state.data!) ListTile(dense: true,
        title: Text('${row['name']}'), subtitle: Text(row.entries.where((e) => e.key != 'name')
          .map((e) => '${e.key}: ${e.value ?? 'NULL'}').join(' · ')))]);
    })],
  );

  Widget category(String kind, String label, IconData icon) => ExpansionTile(
    key: ValueKey('${widget.server.id}/${widget.database}/$kind'),
    initiallyExpanded: kind == 'tables', leading: Icon(icon), title: Text(label),
    onExpansionChanged: (open) => setState(() {
      if (open) { expandedKinds.add(kind); } else { expandedKinds.remove(kind); }
    }),
    children: [if (expandedKinds.contains(kind)) FutureBuilder<List<SqlObject>>(future: load(kind), builder: (context, state) {
      if (state.hasError) return Padding(padding: const EdgeInsets.all(12), child: SelectableText('${state.error}'));
      if (!state.hasData) return const LinearProgressIndicator();
      final found = state.data!.where((o) => '${o.schema}.${o.name}'.toLowerCase().contains(search)).toList();
      if (found.isEmpty) return ListTile(title: Text(tr('موردی پیدا نشد', 'No objects found')));
      return Column(children: [for (final o in found) ExpansionTile(
        key: PageStorageKey('${widget.server.id}/${widget.database}/${o.fullName}'),
        leading: Icon(icon, size: 18), title: Text('${o.schema}.${o.name}', textDirection: TextDirection.ltr),
        children: [
          if (kind == 'tables' || kind == 'views') ...[
            detailNode(o, 'Columns', Icons.view_column_outlined),
            detailNode(o, 'Keys', Icons.key_outlined),
            detailNode(o, 'Indexes', Icons.list_alt_outlined),
            for (final count in [100, 1000]) ListTile(dense: true,
              leading: const Icon(Icons.play_arrow_outlined), title: Text('SELECT TOP $count'),
              onTap: () => widget.onQuery('SELECT TOP ($count) * FROM ${o.fullName};')),
            if (kind == 'tables') Wrap(children: [for (final action in ['INSERT', 'UPDATE', 'DELETE'])
              TextButton(onPressed: () => script(o, action), child: Text('Script $action'))]),
          ],
          if (kind != 'tables') ListTile(dense: true, leading: const Icon(Icons.description_outlined),
            title: Text(tr('نمایش اسکریپت تعریف', 'Script definition')), onTap: () => script(o, 'definition')),
        ],
      )]);
    })],
  );

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(12), children: [
    Card(child: ExpansionTile(initiallyExpanded: true, leading: const Icon(Icons.dns_outlined),
      title: Text(widget.server.name), subtitle: Text('${widget.server.host}:${widget.server.port}'),
      trailing: IconButton(tooltip: tr('تازه‌سازی', 'Refresh'), onPressed: () {
        setState(() { objects.clear(); details.clear(); }); widget.onRefresh();
      }, icon: const Icon(Icons.refresh)),
      children: [for (final db in widget.databases) ListTile(dense: true,
        leading: const Icon(Icons.storage_outlined), title: Text(db), selected: db == widget.database,
        onTap: () => widget.onDatabase(db))])),
    const SizedBox(height: 8),
    TextField(onChanged: (v) => setState(() => search = v.toLowerCase()),
      decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('جستجوی آبجکت در دیتابیس', 'Search database objects'))),
    ListTile(title: Text(widget.database), subtitle: const Text('Object Explorer'),
      trailing: IconButton(tooltip: tr('کوئری جدید', 'New query'), onPressed: () => widget.onQuery(''), icon: const Icon(Icons.add_box_outlined))),
    category('tables', tr('جدول‌ها', 'Tables'), Icons.table_chart_outlined),
    category('views', tr('ویوها', 'Views'), Icons.view_quilt_outlined),
    category('procedures', tr('پروسیجرها', 'Stored procedures'), Icons.functions),
    category('functions', tr('توابع', 'Functions'), Icons.integration_instructions_outlined),
  ]);
}
