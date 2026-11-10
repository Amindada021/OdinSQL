import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mssql_native/mssql_native.dart';
import 'data/server_repository.dart';
import 'data/sql_manager.dart';
import 'models/server_profile.dart';
import 'ui/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appSettings.load();
  await MssqlRuntime.instance.initialize();
  runApp(const OdinSqlApp());
}

class OdinSqlApp extends StatelessWidget {
  const OdinSqlApp({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appSettings,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OdinSQL', theme: studioTheme(Brightness.light),
      darkTheme: studioTheme(Brightness.dark), themeMode: appSettings.theme,
      builder: (context, child) => Directionality(
        textDirection: appSettings.persian ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
      home: const SqlHome(),
    ),
  );
}

class QueryTab {
  QueryTab(this.serverId, this.database, [String sql = ''])
      : id = DateTime.now().microsecondsSinceEpoch.toString(),
        editor = TextEditingController(text: sql);
  final String id, serverId, database;
  final TextEditingController editor;
  MssqlExecutionResult? result;
  String? error;
  bool running = false;
}

class SqlHome extends StatefulWidget {
  const SqlHome({super.key});
  @override
  State<SqlHome> createState() => _SqlHomeState();
}

class _SqlHomeState extends State<SqlHome> {
  final store = ServerRepository();
  final sql = SqlManager();
  final List<QueryTab> tabs = [];
  List<ServerProfile> profiles = [];
  List<String> databases = [];
  List<SqlTable> tables = [];
  ServerProfile? selected;
  String? selectedDb;
  String? selectedTab;
  int page = 0;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    for (final tab in tabs) { tab.editor.dispose(); }
    unawaited(sql.closeAll());
    super.dispose();
  }

  Future<void> reload() async {
    final items = await store.list();
    if (mounted) setState(() => profiles = items);
  }

  void notify(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<String> password(ServerProfile p) async {
    final pass = await store.passwordFor(p);
    if (pass == null || pass.isEmpty) throw StateError('رمز این اتصال ذخیره نشده است.');
    return pass;
  }

  Future<void> connect(ServerProfile p) async {
    setState(() {
      selected = p; selectedDb = p.startDatabase; databases = []; tables = [];
      error = null; loading = true; page = 1;
    });
    try {
      final pass = await password(p);
      final names = await sql.databases(p, pass);
      final db = names.contains(p.startDatabase) ? p.startDatabase
          : (names.isEmpty ? p.startDatabase : names.first);
      final found = await sql.tables(p, db, pass);
      if (mounted && selected?.id == p.id) setState(() {
        databases = names; selectedDb = db; tables = found;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> useDb(String db) async {
    final p = selected;
    if (p == null) return;
    setState(() { selectedDb = db; loading = true; tables = []; error = null; });
    try {
      final found = await sql.tables(p, db, await password(p));
      if (mounted && selectedDb == db && selected?.id == p.id) {
        setState(() => tables = found);
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void newTab([String query = '']) {
    final p = selected, db = selectedDb;
    if (p == null || db == null) return;
    final tab = QueryTab(p.id, db, query);
    setState(() { tabs.add(tab); selectedTab = tab.id; page = 2; });
  }

  QueryTab? get currentTab {
    for (final t in tabs) {
      if (t.id == selectedTab && t.serverId == selected?.id) return t;
    }
    return null;
  }

  void closeTab(QueryTab tab) {
    setState(() {
      tabs.remove(tab);
      if (selectedTab == tab.id) {
        final related = tabs.where((t) => t.serverId == tab.serverId).toList();
        selectedTab = related.isEmpty ? null : related.last.id;
      }
    });
    tab.editor.dispose();
  }

  Future<void> run(QueryTab tab) async {
    if (tab.running || tab.editor.text.trim().isEmpty) return;
    final p = profiles.where((p) => p.id == tab.serverId).firstOrNull;
    if (p == null) return;
    final statement = tab.editor.text;
    final dangerous = RegExp(
      r'\b(INSERT|UPDATE|DELETE|MERGE|DROP|TRUNCATE|ALTER|CREATE|EXEC|EXECUTE|'
      r'BACKUP|RESTORE|GRANT|DENY|REVOKE)\b', caseSensitive: false);
    if (dangerous.hasMatch(statement)) {
      final ok = await showDialog<bool>(context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تأیید اجرای کوئری'),
          content: Text('این دستور ممکن است دیتابیس ${tab.database} را تغییر دهد. اجرا شود؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('اجرا')),
          ],
        ));
      if (ok != true) return;
    }
    setState(() { tab.running = true; tab.error = null; tab.result = null; });
    try {
      final value = await sql.query(p, tab.database, await password(p), statement);
      if (mounted && tabs.contains(tab)) setState(() => tab.result = value);
    } catch (e) {
      if (mounted && tabs.contains(tab)) setState(() => tab.error = e.toString());
    } finally {
      if (mounted && tabs.contains(tab)) setState(() => tab.running = false);
    }
  }

  Future<void> edit([ServerProfile? old]) async {
    final value = await showDialog<EditedServer>(context: context,
      builder: (_) => ServerEditor(old));
    if (value == null) return;
    try {
      if (old != null) await sql.closeServer(old);
      await store.save(value.profile, password: value.password);
      await reload();
      if (selected?.id == value.profile.id) {
        setState(() { selected = null; page = 0; });
      }
    } catch (e) { notify(e); }
  }

  Future<void> remove(ServerProfile p) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('حذف ${p.name}'),
      content: const Text('تنها مشخصات اتصال از گوشی پاک می‌شود؛ دیتابیس حذف نمی‌شود.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
      ],
    ));
    if (ok != true) return;
    await sql.closeServer(p);
    await store.remove(p);
    final owned = tabs.where((t) => t.serverId == p.id).toList();
    for (final t in owned) { tabs.remove(t); t.editor.dispose(); }
    if (selected?.id == p.id) {
      setState(() { selected = null; selectedTab = null; page = 0; });
    }
    await reload();
  }

  Widget avatar(ServerProfile p) {
    final content = p.imageBase64 == null ? null : base64Decode(p.imageBase64!);
    return Container(
      width: 46, height: 46, clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Color(p.colorValue), borderRadius: BorderRadius.circular(12)),
      child: content == null ? const Icon(Icons.dns, color: Colors.white) :
        Image.memory(content, fit: BoxFit.cover),
    );
  }

  Widget servers() => ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 100), children: [
    Text(tr('سرورهای من', 'My servers'), style: Theme.of(context).textTheme.headlineSmall),
    const SizedBox(height: 12),
    if (profiles.isEmpty) const Padding(
      padding: EdgeInsets.all(24),
      child: Text('هنوز سروری ثبت نشده؛ با دکمه + سرور جدید اضافه کنید.'),
    ),
    for (final p in profiles) Card(
      child: ListTile(
        leading: avatar(p),
        title: Text(p.name),
        subtitle: Text('${p.host}:${p.port}  •  ${p.username}'),
        onTap: () => connect(p),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => v == 'edit' ? edit(p) : remove(p),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('ویرایش')),
            PopupMenuItem(value: 'delete', child: Text('حذف')),
          ],
        ),
      ),
    ),
  ]);

  Future<void> showColumns(SqlTable t) async {
    final p = selected, db = selectedDb;
    if (p == null || db == null) return;
    try {
      final columns = await sql.columns(p, db, await password(p), t);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context, isScrollControlled: true,
        builder: (_) => SafeArea(
          child: SizedBox(height: MediaQuery.sizeOf(context).height * .7,
            child: Column(children: [
              ListTile(title: Text('${t.schema}.${t.name}')),
              Expanded(child: ListView(children: [
                for (final column in columns)
                  ListTile(title: Text('${column['column_name']}'),
                    subtitle: Text('${column['data_type']}  •  Nullable: ${column['nullable']}')),
              ])),
            ]),
          ),
        ),
      );
    } catch (e) { notify(e); }
  }

  Widget explorer() {
    final p = selected;
    if (p == null) return const Center(child: Text('ابتدا یک سرور انتخاب کنید.'));
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(child: ListTile(
        leading: avatar(p), title: Text(p.name),
        subtitle: Text('${p.host}:${p.port}'),
        trailing: IconButton(onPressed: loading ? null : () => connect(p), icon: const Icon(Icons.refresh)),
      )),
      if (loading) const LinearProgressIndicator(),
      if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
      if (databases.isNotEmpty) DropdownButtonFormField<String>(
        value: selectedDb,
        decoration: const InputDecoration(labelText: 'Database'),
        items: [for (final name in databases) DropdownMenuItem(value: name, child: Text(name))],
        onChanged: loading ? null : (db) { if (db != null) useDb(db); },
      ),
      const SizedBox(height: 14),
      Row(children: [
        Text('Tables (${tables.length})', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        TextButton.icon(onPressed: () => newTab(), icon: const Icon(Icons.add), label: const Text('New Query')),
      ]),
      for (final t in tables) Card(child: ExpansionTile(
        leading: const Icon(Icons.table_chart_outlined), title: Text('${t.schema}.${t.name}'),
        children: [
          ListTile(leading: const Icon(Icons.view_column_outlined),
            title: const Text('Columns'), onTap: () => showColumns(t)),
          ListTile(leading: const Icon(Icons.play_arrow_outlined),
            title: const Text('Select Top 100'),
            onTap: () => newTab('SELECT TOP (100) * FROM ${t.fullName};')),
        ],
      )),
    ]);
  }

  Widget resultTable(MssqlResultSet set) {
    if (set.columns.isEmpty) return const Text('بدون ستون');
    return SingleChildScrollView(scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [for (final c in set.columns) DataColumn(label: Text(c.name))],
        rows: [for (final record in set.rows)
          DataRow(cells: [for (final c in set.columns)
            DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240),
              child: Text('${record[c.name] ?? 'NULL'}', maxLines: 3, overflow: TextOverflow.ellipsis)))])],
      ));
  }

  Widget queries() {
    if (selected == null) return const Center(child: Text('ابتدا سرور را انتخاب کنید.'));
    final visible = tabs.where((t) => t.serverId == selected?.id).toList();
    final tab = currentTab;
    return Column(children: [
      SizedBox(height: 54, child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final t in visible) Padding(padding: const EdgeInsets.all(4),
          child: InputChip(
            selected: selectedTab == t.id, label: Text(t.database),
            onPressed: () => setState(() => selectedTab = t.id),
            onDeleted: () => closeTab(t))),
        IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => newTab()),
      ])),
      if (tab == null) Expanded(child: Center(child:
        FilledButton.icon(onPressed: () => newTab(), icon: const Icon(Icons.add),
          label: const Text('New Query'))))
      else Expanded(child: Column(children: [
        ListTile(
          dense: true,
          title: Text('${selected?.name} / ${tab.database}'),
          trailing: FilledButton.icon(
            onPressed: tab.running ? null : () => run(tab),
            icon: const Icon(Icons.play_arrow), label: const Text('Execute')),
        ),
        SizedBox(height: 160, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            controller: tab.editor, expands: true, minLines: null, maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(border: OutlineInputBorder(),
              hintText: 'SELECT TOP (100) * FROM dbo.MyTable;'),
          ))),
        if (tab.running) const LinearProgressIndicator(),
        if (tab.error != null) Padding(padding: const EdgeInsets.all(8),
          child: Text(tab.error!, style: const TextStyle(color: Colors.redAccent))),
        if (tab.result != null) Padding(padding: const EdgeInsets.all(6),
          child: Text('Affected Rows: ${tab.result!.affectedRows}  •  Result Sets: ${tab.result!.resultSets.length}')),
        Expanded(child: ListView(children: [
          if (tab.result != null)
            for (var i = 0; i < tab.result!.resultSets.length; i++) ...[
              ListTile(title: Text('Result ${i + 1}  •  ${tab.result!.resultSets[i].rows.length} rows')),
              resultTable(tab.result!.resultSets[i]),
            ],
        ])),
      ])),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final destinations = [
      NavigationDestination(icon: const Icon(Icons.dns_outlined), label: tr('سرورها', 'Servers')),
      NavigationDestination(icon: const Icon(Icons.account_tree_outlined), label: tr('کاوشگر', 'Explorer')),
      NavigationDestination(icon: const Icon(Icons.code), label: 'SQL'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.storage_rounded, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Flexible(child: Text(selected == null ? 'OdinSQL' : 'OdinSQL · ${selected!.name}', overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          if (selected != null) IconButton(tooltip: tr('کوئری جدید', 'New query'),
            onPressed: () => newTab(), icon: const Icon(Icons.add_box_outlined)),
          IconButton(tooltip: tr('تنظیمات', 'Settings'), onPressed: () => showStudioSettings(context),
            icon: const Icon(Icons.tune_rounded)),
        ],
      ),
      body: Row(children: [
        if (wide) NavigationRail(selectedIndex: page,
          onDestinationSelected: (i) => setState(() => page = i),
          labelType: NavigationRailLabelType.all,
          destinations: [for (final d in destinations) NavigationRailDestination(icon: d.icon, label: Text(d.label))]),
        Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(key: ValueKey(page), child: [servers, explorer, queries][page]()))),
      ]),
      floatingActionButton: page == 0 ? FloatingActionButton.extended(
        onPressed: () => edit(), icon: const Icon(Icons.add), label: Text(tr('سرور جدید', 'Add server')),
      ) : null,
      bottomNavigationBar: wide ? null : NavigationBar(
        selectedIndex: page, onDestinationSelected: (i) => setState(() => page = i), destinations: destinations),
    );
  }
}

class EditedServer {
  EditedServer(this.profile, this.password);
  final ServerProfile profile;
  final String? password;
}

class ServerEditor extends StatefulWidget {
  const ServerEditor(this.existing, {super.key});
  final ServerProfile? existing;
  @override
  State<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<ServerEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final host = TextEditingController(text: widget.existing?.host ?? '');
  late final port = TextEditingController(text: '${widget.existing?.port ?? 1433}');
  late final user = TextEditingController(text: widget.existing?.username ?? 'sa');
  late final database = TextEditingController(text: widget.existing?.startDatabase ?? 'master');
  final password = TextEditingController();
  late int colorValue = widget.existing?.colorValue ?? 0xff3867d6;
  late String? picture = widget.existing?.imageBase64;

  @override
  void dispose() {
    name.dispose(); host.dispose(); port.dispose(); user.dispose();
    database.dispose(); password.dispose(); super.dispose();
  }

  Future<void> pickImage() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery,
      maxWidth: 350, maxHeight: 350, imageQuality: 65);
    if (image == null) return;
    final bytes = await image.readAsBytes();
    if (bytes.length > 300000) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('عکس خیلی بزرگ است.')));
      return;
    }
    if (mounted) setState(() => picture = base64Encode(bytes));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'سرور جدید' : 'ویرایش سرور'),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Form(
      key: form,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: name, decoration: const InputDecoration(labelText: 'نام دلخواه'),
          validator: (v) => v == null || v.trim().isEmpty ? 'نام را وارد کنید' : null),
        TextFormField(controller: host, decoration: const InputDecoration(labelText: 'IP / Host'),
          validator: (v) => v == null || v.trim().isEmpty ? 'IP را وارد کنید' : null),
        TextFormField(controller: port, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'TCP Port'),
          validator: (v) => (int.tryParse(v ?? '') ?? 0) < 1 ||
              (int.tryParse(v ?? '') ?? 0) > 65535 ? 'پورت نامعتبر' : null),
        TextFormField(controller: user, decoration: const InputDecoration(labelText: 'Username'),
          validator: (v) => v == null || v.trim().isEmpty ? 'نام کاربری را وارد کنید' : null),
        TextFormField(controller: password, obscureText: true,
          decoration: InputDecoration(labelText: widget.existing == null
              ? 'Password' : 'Password (خالی = بدون تغییر)'),
          validator: (v) => widget.existing == null && (v == null || v.isEmpty)
            ? 'رمز عبور را وارد کنید' : null),
        TextFormField(controller: database,
          decoration: const InputDecoration(labelText: 'Initial Database')),
        const SizedBox(height: 12),
        Wrap(spacing: 10, children: [
          for (final c in const [0xff3867d6, 0xff229d85, 0xffd06a3b,
            0xff9446b1, 0xffda4267, 0xff6b7582])
            InkWell(onTap: () => setState(() => colorValue = c),
              child: CircleAvatar(backgroundColor: Color(c), radius: 17,
                child: c == colorValue ? const Icon(Icons.check, size: 18) : null)),
        ]),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: pickImage, icon: const Icon(Icons.image_outlined),
          label: Text(picture == null ? 'انتخاب عکس سرور' : 'تغییر عکس')),
      ]),
    ))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
      FilledButton(onPressed: () {
        if (!form.currentState!.validate()) return;
        final p = ServerProfile(
          id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
          name: name.text.trim(), host: host.text.trim(),
          port: int.parse(port.text), username: user.text.trim(),
          startDatabase: database.text.trim().isEmpty ? 'master' : database.text.trim(),
          colorValue: colorValue, imageBase64: picture,
        );
        Navigator.pop(context, EditedServer(p, password.text.isEmpty ? null : password.text));
      }, child: const Text('ذخیره')),
    ],
  );
}

