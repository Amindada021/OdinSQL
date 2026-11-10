import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mssql_native/mssql_native.dart';
import 'data/server_repository.dart';
import 'data/sql_manager.dart';
import 'models/server_profile.dart';
import 'ui/app_settings.dart';
import 'ui/object_explorer.dart';
import 'ui/sql_editor.dart';
import 'ui/result_pane.dart';
import 'data/query_repository.dart';
import 'ui/query_library.dart';

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
      locale: Locale(appSettings.persian ? 'fa' : 'en'),
      supportedLocales: const [Locale('fa'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
  QueryTab(this.serverId, this.database, {String sql = '', String? restoredId})
      : id = restoredId ?? DateTime.now().microsecondsSinceEpoch.toString(),
        editor = SqlEditingController(text: sql);
  final String id, serverId;
  String database;
  final SqlEditingController editor;
  final UndoHistoryController undo = UndoHistoryController();
  MssqlCancellationToken? cancellation;
  Duration? elapsed;
  bool confirming = false;
  bool editorOnly = false;
  MssqlExecutionResult? result;
  String? error;
  bool running = false;
}

class SqlHome extends StatefulWidget {
  const SqlHome({super.key});
  @override
  State<SqlHome> createState() => _SqlHomeState();
}

class _SqlHomeState extends State<SqlHome> with WidgetsBindingObserver {
  final store = ServerRepository();
  final queryStore = QueryRepository();
  Timer? persistTimer;
  bool booting = true;
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
  String serverSearch = '';
  bool favoritesOnly = false;
  int explorerRequest = 0;
  final Set<String> testing = {};
  bool busyServer(String id) => tabs.any((t) => t.serverId == id && (t.running || t.confirming));

  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appSettings.addListener(settingsChanged);
    restoreWorkspace();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appSettings.removeListener(settingsChanged);
    persistTimer?.cancel();
    persistWorkspace();
    for (final tab in tabs) { tab.cancellation?.cancel(); tab.editor.dispose(); tab.undo.dispose(); }
    unawaited(sql.closeAll());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { persistTimer?.cancel(); persistWorkspace(); }
  }

  void settingsChanged() { if (mounted) setState(() {}); }

  void schedulePersist() {
    persistTimer?.cancel();
    persistTimer = Timer(const Duration(milliseconds: 500), persistWorkspace);
  }

  void persistWorkspace() {
    if (booting) return;
    unawaited(queryStore.saveWorkspace({
      'selectedTab': selectedTab, 'selectedServer': selected?.id,
      'tabs': [for (final t in tabs) {'id': t.id, 'serverId': t.serverId, 'database': t.database, 'sql': t.editor.text}],
    }).catchError((Object e) { notify(tr('ذخیره تب‌ها ناموفق بود: $e', 'Could not save tabs: $e')); }));
  }

  Future<void> restoreWorkspace() async {
    try {
      final items = await store.list();
      final value = await queryStore.workspace();
      if (!mounted) return;
      final restored = <QueryTab>[];
      for (final raw in (value['tabs'] as List? ?? [])) {
        final entry = raw as Map<String, dynamic>;
        if (!items.any((p) => p.id == entry['serverId'])) continue;
        final tab = QueryTab(entry['serverId'] as String, entry['database'] as String,
          sql: entry['sql'] as String? ?? '', restoredId: entry['id'] as String?);
        tab.editor.addListener(schedulePersist); restored.add(tab);
      }
      setState(() {
        profiles = items; tabs.addAll(restored);
        selectedTab = value['selectedTab'] as String?;
        selected = items.where((p) => p.id == value['selectedServer']).firstOrNull;
        selectedDb = currentTab?.database ?? selected?.startDatabase;
        if (currentTab != null) page = 2;
      });
    } catch (e) { notify(e); await reload(); }
    finally { if (mounted) setState(() => booting = false); }
  }

  Future<void> saveQuery(QueryTab tab) async {
    if (tab.editor.text.trim().isEmpty) return;
    final title = TextEditingController(text: '${tab.database} query');
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(tr('ذخیره کوئری', 'Save query')),
      content: TextField(controller: title, autofocus: true, decoration: InputDecoration(labelText: tr('عنوان', 'Title'))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('انصراف', 'Cancel'))),
        FilledButton(onPressed: () { if (title.text.trim().isNotEmpty) Navigator.pop(ctx, title.text.trim()); }, child: Text(tr('ذخیره', 'Save')))],
    ));
    title.dispose();
    if (name == null) return;
    try {
      await queryStore.add({'id': DateTime.now().microsecondsSinceEpoch.toString(), 'title': name,
        'serverId': tab.serverId, 'database': tab.database, 'sql': tab.editor.text, 'at': DateTime.now().toIso8601String()}, saved: true);
      notify(tr('کوئری ذخیره شد.', 'Query saved.'));
    } catch (e) { notify(e); }
  }

  Future<void> openQueryLibrary() async {
    final entry = await showModalBottomSheet<Map<String, dynamic>>(context: context,
      isScrollControlled: true, showDragHandle: true,
      builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * .85,
        child: QueryLibrary(repository: queryStore, serverNames: {for (final p in profiles) p.id: p.name})));
    if (!mounted || entry == null) return;
    final server = profiles.where((p) => p.id == entry['serverId']).firstOrNull;
    if (server == null) return;
    setState(() {
      if (selected?.id != server.id) { databases = []; tables = []; }
      ++explorerRequest; selected = server; selectedDb = entry['database'] as String; loading = false;
    });
    newTab(entry['sql'] as String);
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
    if (pass == null || pass.isEmpty) throw StateError(tr('رمز این اتصال ذخیره نشده است.', 'No password is saved for this connection.'));
    return pass;
  }

  Future<void> connect(ServerProfile p, {String? database}) async {
    final request = ++explorerRequest;
    setState(() {
      selectedTab = tabs.where((t) => t.serverId == p.id).lastOrNull?.id;
      schedulePersist();
      selected = p; selectedDb = database ?? p.startDatabase; databases = []; tables = [];
      error = null; loading = true; page = 1;
    });
    try {
      final pass = await password(p);
      final names = await sql.databases(p, pass);
      final preferred = database ?? p.startDatabase;
      final db = names.contains(preferred) ? preferred
          : (names.isEmpty ? preferred : names.first);
      final found = await sql.tables(p, db, pass);
      if (mounted && request == explorerRequest) setState(() {
        databases = names; selectedDb = db; tables = found;
      });
    } catch (e) {
      if (mounted && request == explorerRequest) setState(() => error = e.toString());
    } finally {
      if (mounted && request == explorerRequest) setState(() => loading = false);
    }
  }

  Future<void> useDb(String db) async {
    final p = selected;
    if (p == null) return;
    final request = ++explorerRequest;
    setState(() { selectedDb = db; loading = true; tables = []; error = null; });
    try {
      final found = await sql.tables(p, db, await password(p));
      if (mounted && request == explorerRequest) {
        setState(() => tables = found);
      }
    } catch (e) {
      if (mounted && request == explorerRequest) setState(() => error = e.toString());
    } finally {
      if (mounted && request == explorerRequest) setState(() => loading = false);
    }
  }

  void newTab([String query = '']) {
    final p = selected, db = selectedDb;
    if (p == null || db == null) return;
    final tab = QueryTab(p.id, db, sql: query);
    tab.editor.addListener(schedulePersist);
    setState(() { tabs.add(tab); selectedTab = tab.id; page = 2; });
    schedulePersist();
  }

  QueryTab? get currentTab {
    for (final t in tabs) {
      if (t.id == selectedTab && t.serverId == selected?.id) return t;
    }
    return null;
  }

  void closeTab(QueryTab tab) {
    if (tab.running || tab.confirming) return;
    unawaited(sql.closeQuerySession(tab.id).catchError((Object e) { notify(e); }));
    setState(() {
      tabs.remove(tab);
      if (selectedTab == tab.id) {
        final related = tabs.where((t) => t.serverId == tab.serverId).toList();
        selectedTab = related.isEmpty ? null : related.last.id;
      }
    });
    tab.editor.dispose(); tab.undo.dispose();
    schedulePersist();
  }

  Future<void> run(QueryTab tab) async {
    if (tab.running || tab.confirming || tab.editor.text.trim().isEmpty) return;
    final p = profiles.where((p) => p.id == tab.serverId).firstOrNull;
    if (p == null) return;
    final database = tab.database;
    final selection = tab.editor.selection;
    final statement = selection.isValid && !selection.isCollapsed
      ? selection.textInside(tab.editor.text) : tab.editor.text;
    if (statement.trim().isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    tab.confirming = true;
    final dangerous = RegExp(
      r'\b(INSERT|UPDATE|DELETE|MERGE|DROP|TRUNCATE|ALTER|CREATE|EXEC|EXECUTE|'
      r'BACKUP|RESTORE|GRANT|DENY|REVOKE|DBCC|KILL|SHUTDOWN|RECONFIGURE)\b', caseSensitive: false);
    if (dangerous.hasMatch(statement)) {
      final ok = await showDialog<bool>(context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('تأیید اجرای کوئری', 'Confirm execution')),
          content: Text(tr('این دستور ممکن است دیتابیس ${p.name} / $database را تغییر دهد. اجرا شود؟', 'This statement may change ${p.name} / $database. Execute?')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('انصراف', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('اجرا', 'Execute'))),
          ],
        ));
      if (ok != true) { tab.confirming = false; return; }
    }
    tab.confirming = false;
    if (!mounted || !tabs.contains(tab)) return;
    final timer = Stopwatch()..start();
    final token = MssqlCancellationToken();
    setState(() { tab.running = true; tab.error = null; tab.result = null; tab.elapsed = null; tab.cancellation = token; });
    try {
      final value = await sql.query(p, database, await password(p), statement, sessionId: tab.id, cancellationToken: token);
      if (mounted && tabs.contains(tab)) setState(() => tab.result = value);
    } catch (e) {
      if (mounted && tabs.contains(tab)) setState(() => tab.error = e.toString());
    } finally {
      timer.stop();
      if (mounted && tabs.contains(tab)) setState(() {
        tab.running = false; tab.cancellation = null; tab.elapsed = timer.elapsed;
      });
      try {
        await queryStore.add({'id': DateTime.now().microsecondsSinceEpoch.toString(),
          'serverId': p.id, 'database': database, 'sql': statement, 'title': statement.trim().split('\n').first,
          'at': DateTime.now().toIso8601String(), 'elapsedMs': timer.elapsedMilliseconds, 'success': tab.error == null}, saved: false);
      } catch (e) { notify(e); }
    }
  }

  Future<void> edit([ServerProfile? old]) async {
    if (old != null && busyServer(old.id)) { notify(tr('منتظر پایان کوئری بمانید.', 'Wait for running queries to finish.')); return; }
    final value = await showDialog<EditedServer>(context: context,
      builder: (_) => ServerEditor(old));
    if (!mounted || value == null) return;
    if (old != null && busyServer(old.id)) return;
    try {
      ++explorerRequest;
      if (old != null) await sql.closeServer(old);
      await store.save(value.profile, password: value.password);
      await reload();
      if (selected?.id == value.profile.id && mounted) {
        setState(() { selected = null; page = 0; loading = false; });
      }
      schedulePersist();
    } catch (e) { notify(e); }
  }

  Future<void> remove(ServerProfile p) async {
    if (busyServer(p.id)) { notify(tr('منتظر پایان کوئری بمانید.', 'Wait for running queries to finish.')); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(tr('حذف ${p.name}', 'Remove ${p.name}')),
      content: Text(tr('تنها مشخصات اتصال از گوشی پاک می‌شود؛ دیتابیس حذف نمی‌شود.', 'Remove this connection profile from your phone? The database is preserved.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('انصراف', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('حذف', 'Delete'))),
      ],
    ));
    if (!mounted || ok != true || busyServer(p.id)) return;
    ++explorerRequest;
    await sql.closeServer(p);
    await store.remove(p);
    if (!mounted) return;
    final owned = tabs.where((t) => t.serverId == p.id).toList();
    for (final t in owned) { tabs.remove(t); t.editor.dispose(); t.undo.dispose(); }
    if (selected?.id == p.id) {
      setState(() { selected = null; selectedTab = null; page = 0; });
    }
    await reload();
    schedulePersist();
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

  Future<void> showServerInfo(ServerProfile p) async {
    final info = () async => sql.serverInfo(p, await password(p));
    final future = info();
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: Text(tr('اطلاعات سرور', 'Server information')),
      content: SizedBox(width: 500, child: FutureBuilder<Map<String, Object?>>(
        future: future, builder: (context, state) {
          if (state.hasError) return SelectableText('${state.error}');
          if (!state.hasData) return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
          return SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [for (final item in state.data!.entries)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: SelectableText('${item.key}\n${item.value ?? 'NULL'}'))]));
        })),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('بستن', 'Close')))],
    ));
  }

  Future<void> toggleFavorite(ServerProfile p) async {
    try { await store.save(p.withFavorite(!p.favorite)); await reload(); }
    catch (e) { notify(e); }
  }

  Future<void> testServer(ServerProfile p) async {
    if (testing.contains(p.id)) return;
    setState(() => testing.add(p.id));
    final probe = SqlManager();
    try {
      final c = await probe.open(p, p.startDatabase, await password(p));
      await c.queryRows('SELECT 1 AS connected');
      notify(tr('اتصال موفق بود: ${p.name}', 'Connection successful: ${p.name}'));
    } catch (e) { notify(e); }
    finally {
      await probe.closeAll();
      if (mounted) setState(() => testing.remove(p.id));
    }
  }

  Future<void> disconnect(ServerProfile p) async {
    if (busyServer(p.id)) { notify(tr('منتظر پایان کوئری بمانید.', 'Wait for running queries to finish.')); return; }
    try {
      await sql.closeServer(p);
      if (!mounted) return;
      setState(() {
        if (selected?.id == p.id) {
          ++explorerRequest; selected = null; selectedDb = null; loading = false; page = 0;
        }
      });
    } catch (e) { notify(e); }
  }

  Widget servers() {
    final search = serverSearch.toLowerCase();
    final visible = profiles.where((p) => (!favoritesOnly || p.favorite) &&
      '${p.name} ${p.host} ${p.username}'.toLowerCase().contains(search)).toList()
      ..sort((a, b) => a.favorite == b.favorite ? a.name.compareTo(b.name) : (a.favorite ? -1 : 1));
    final connected = profiles.where(sql.isConnected).length;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 100), children: [
      Container(padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primaryContainer, Theme.of(context).colorScheme.surface])),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('محیط مدیریت SQL Server', 'SQL Server workspace'), style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(tr('${profiles.length} سرور · $connected اتصال فعال', '${profiles.length} servers · $connected connected')),
        ])),
      const SizedBox(height: 16),
      TextField(onChanged: (v) => setState(() => serverSearch = v),
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('جستجوی نام یا آدرس سرور', 'Search servers by name or host'))),
      Align(alignment: AlignmentDirectional.centerStart, child: FilterChip(
        avatar: const Icon(Icons.star_outline, size: 18), label: Text(tr('علاقه‌مندی‌ها', 'Favorites')),
        selected: favoritesOnly, onSelected: (v) => setState(() => favoritesOnly = v))),
      if (visible.isEmpty) Padding(padding: const EdgeInsets.all(24),
        child: Text(tr('سروری پیدا نشد. با + سرور جدید اضافه کنید.', 'No servers found. Add a server with +.'))),
      for (final p in visible) Card(clipBehavior: Clip.antiAlias, child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: avatar(p), title: Text(p.name),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p.host}:${p.port} · ${p.username}', textDirection: TextDirection.ltr),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.circle, size: 8, color: sql.isConnected(p) ? Colors.teal : Theme.of(context).colorScheme.outline),
            const SizedBox(width: 6),
            Text(testing.contains(p.id) ? tr('در حال تست…', 'Testing…') :
              sql.isConnected(p) ? tr('متصل', 'Connected') : tr('قطع', 'Disconnected')),
          ]),
        ]),
        onTap: () => connect(p),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: tr('علاقه‌مندی', 'Favorite'), onPressed: () => toggleFavorite(p),
            icon: Icon(p.favorite ? Icons.star_rounded : Icons.star_outline_rounded, color: p.favorite ? Colors.amber : null)),
          PopupMenuButton<String>(onSelected: (v) {
            switch (v) {
              case 'edit': edit(p); break;
              case 'test': testServer(p); break;
              case 'info': showServerInfo(p); break;
              case 'disconnect': disconnect(p); break;
              case 'delete': remove(p); break;
            }
          }, itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr('ویرایش', 'Edit'))),
            PopupMenuItem(value: 'info', child: Text(tr('اطلاعات سرور', 'Server information'))),
            PopupMenuItem(value: 'test', enabled: !testing.contains(p.id), child: Text(tr('تست اتصال', 'Test connection'))),
            PopupMenuItem(value: 'disconnect', enabled: sql.isConnected(p), child: Text(tr('قطع اتصال', 'Disconnect'))),
            PopupMenuItem(value: 'delete', child: Text(tr('حذف', 'Delete'))),
          ]),
        ]),
      )),
    ]);
  }

  Widget explorer() {
    final p = selected, db = selectedDb;
    if (p == null || db == null) return Center(child: Text(tr('ابتدا یک سرور انتخاب کنید.', 'Select a server first.')));
    return Column(children: [
      if (loading) const LinearProgressIndicator(),
      if (error != null) Padding(padding: const EdgeInsets.all(12), child: SelectableText(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Expanded(child: ObjectExplorer(key: ValueKey('${p.id}/$db/$explorerRequest'),
        server: p, database: db, databases: databases, manager: sql, password: () => password(p),
        onDatabase: useDb, onQuery: newTab, onRefresh: () => connect(p, database: db))),
    ]);
  }

  Widget queries() {
    if (selected == null) return Center(child: Text(tr('ابتدا سرور را انتخاب کنید.', 'Select a server first.')));
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final visible = tabs.where((t) => t.serverId == selected?.id).toList();
    final tab = currentTab;
    return Column(children: [
      SizedBox(height: keyboard ? 40 : 48, child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final t in visible) Padding(padding: const EdgeInsets.all(4),
          child: InputChip(
            selected: selectedTab == t.id, label: Text('${visible.indexOf(t) + 1} · ${t.database}'),
            onPressed: () { setState(() => selectedTab = t.id); schedulePersist(); },
            onDeleted: t.running || t.confirming ? null : () => closeTab(t))),
        IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => newTab()),
      ])),
      if (tab == null) Expanded(child: Center(child:
        FilledButton.icon(onPressed: () => newTab(), icon: const Icon(Icons.add),
          label: Text(tr('کوئری جدید', 'New query')))))
      else Expanded(child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          Expanded(child: DropdownButton<String>(isExpanded: true, value: tab.database,
            items: [for (final db in {tab.database, ...databases}) DropdownMenuItem(value: db, child: Text(db, overflow: TextOverflow.ellipsis))],
            onChanged: tab.running ? null : (db) { if (db != null) { setState(() => tab.database = db); schedulePersist(); } })),
          const SizedBox(width: 8),
          if (tab.running) IconButton(tooltip: tr('لغو اجرا', 'Cancel query'),
            onPressed: () => tab.cancellation?.cancel('Cancelled by user'), icon: const Icon(Icons.stop_circle_outlined))
          else FilledButton.icon(onPressed: () => run(tab), icon: const Icon(Icons.play_arrow), label: Text(tr('اجرا', 'Execute'))),
        ])),
        if (!keyboard) SizedBox(height: 42, child: ListView(scrollDirection: Axis.horizontal, children: [
          ValueListenableBuilder<UndoHistoryValue>(valueListenable: tab.undo, builder: (context, value, _) => Row(children: [
            IconButton(tooltip: tr('واگرد', 'Undo'), onPressed: !tab.running && value.canUndo ? tab.undo.undo : null, icon: const Icon(Icons.undo)),
            IconButton(tooltip: tr('ازنو', 'Redo'), onPressed: !tab.running && value.canRedo ? tab.undo.redo : null, icon: const Icon(Icons.redo)),
          ])),
          IconButton(tooltip: tr('نمایش نتایج', 'Toggle results'), onPressed: () => setState(() => tab.editorOnly = !tab.editorOnly), icon: Icon(tab.editorOnly ? Icons.vertical_split_outlined : Icons.code)),
          IconButton(tooltip: tr('ذخیره کوئری', 'Save query'), onPressed: () => saveQuery(tab), icon: const Icon(Icons.bookmark_add_outlined)),
          TextButton.icon(onPressed: tab.running ? null : () {
            final formatted = formatSql(tab.editor.text);
            tab.editor.value = TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
          }, icon: const Icon(Icons.format_align_left), label: const Text('Format SQL')),
          Padding(padding: const EdgeInsets.all(10), child: Text(tr('انتخاب متن = اجرای همان بخش', 'Select text to execute selection'))),
        ])),
        if (tab.running) const LinearProgressIndicator(),
        Expanded(child: LayoutBuilder(builder: (context, bounds) {
          final editor = SqlEditor(key: ValueKey(tab.id), controller: tab.editor, undo: tab.undo,
            readOnly: tab.running, suggestions: [for (final t in tables) t.name, for (final t in tables) '${t.schema}.${t.name}']);
          if (keyboard || tab.editorOnly) return editor;
          final results = ResultPane(key: ValueKey('result/${tab.id}'), result: tab.result, error: tab.error, elapsed: tab.elapsed);
          if (bounds.maxWidth > 650 && bounds.maxWidth > bounds.maxHeight * 1.4) {
            return Row(children: [Expanded(child: editor), const VerticalDivider(width: 1), Expanded(child: results)]);
          }
          return Column(children: [Expanded(flex: 2, child: editor), const Divider(height: 1), Expanded(flex: 3, child: results)]);
        })),
      ])),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final destinations = [
      NavigationDestination(icon: const Icon(Icons.dns_outlined), label: tr('سرورها', 'Servers')),
      NavigationDestination(icon: const Icon(Icons.account_tree_outlined), label: tr('کاوشگر', 'Explorer')),
      NavigationDestination(icon: const Icon(Icons.code), label: 'SQL'),
    ];
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: keyboard ? 40 : null,
        title: Row(children: [
          Icon(Icons.storage_rounded, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Flexible(child: Text(selected == null ? 'OdinSQL' : 'OdinSQL · ${selected!.name}', overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          IconButton(tooltip: tr('تاریخچه و کوئری‌ها', 'History and saved queries'), onPressed: booting ? null : openQueryLibrary, icon: const Icon(Icons.history)),
          if (selected != null) IconButton(tooltip: tr('کوئری جدید', 'New query'),
            onPressed: () => newTab(), icon: const Icon(Icons.add_box_outlined)),
          IconButton(tooltip: tr('تنظیمات', 'Settings'), onPressed: () => showStudioSettings(context),
            icon: const Icon(Icons.tune_rounded)),
        ],
      ),
      body: booting ? const Center(child: CircularProgressIndicator()) : Row(children: [
        if (wide) NavigationRail(selectedIndex: page,
          onDestinationSelected: (i) => setState(() => page = i),
          labelType: NavigationRailLabelType.all,
          destinations: [for (final d in destinations) NavigationRailDestination(icon: d.icon, label: Text(d.label))]),
        Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(key: ValueKey(page), child: [servers, explorer, queries][page]()))),
      ]),
      floatingActionButton: page == 0 && !booting ? FloatingActionButton.extended(
        onPressed: () => edit(), icon: const Icon(Icons.add), label: Text(tr('سرور جدید', 'Add server')),
      ) : null,
      bottomNavigationBar: wide || keyboard ? null : NavigationBar(
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
  bool testing = false;
  String? testMessage;

  ServerProfile profile() => ServerProfile(
    id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: name.text.trim(), host: host.text.trim(), port: int.parse(port.text),
    username: user.text.trim(), startDatabase: database.text.trim().isEmpty ? 'master' : database.text.trim(),
    colorValue: colorValue, imageBase64: picture, favorite: widget.existing?.favorite ?? false,
  );

  Future<void> testConnection() async {
    if (!form.currentState!.validate() || testing) return;
    setState(() { testing = true; testMessage = null; });
    final manager = SqlManager();
    try {
      final p = profile();
      final pass = password.text.isNotEmpty ? password.text : await ServerRepository().passwordFor(p);
      if (pass == null) throw StateError(tr('رمز عبور را وارد کنید', 'Enter a password'));
      final c = await manager.open(p, p.startDatabase, pass);
      await c.queryRows('SELECT 1 AS connected');
      if (mounted) setState(() => testMessage = tr('اتصال موفق بود', 'Connection successful'));
    } catch (e) { if (mounted) setState(() => testMessage = e.toString()); }
    finally { await manager.closeAll(); if (mounted) setState(() => testing = false); }
  }

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
        SnackBar(content: Text(tr('عکس خیلی بزرگ است.', 'Image is too large.'))));
      return;
    }
    if (mounted) setState(() => picture = base64Encode(bytes));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? tr('سرور جدید', 'Add server') : tr('ویرایش سرور', 'Edit server')),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Form(
      key: form,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: name, decoration: InputDecoration(labelText: tr('نام دلخواه', 'Display name')),
          validator: (v) => v == null || v.trim().isEmpty ? tr('نام را وارد کنید', 'Enter a name') : null),
        TextFormField(controller: host, decoration: const InputDecoration(labelText: 'IP / Host'),
          validator: (v) => v == null || v.trim().isEmpty ? tr('IP را وارد کنید', 'Enter a host or IP') : null),
        TextFormField(controller: port, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'TCP Port'),
          validator: (v) => (int.tryParse(v ?? '') ?? 0) < 1 ||
              (int.tryParse(v ?? '') ?? 0) > 65535 ? tr('پورت نامعتبر', 'Invalid port') : null),
        TextFormField(controller: user, decoration: const InputDecoration(labelText: 'Username'),
          validator: (v) => v == null || v.trim().isEmpty ? tr('نام کاربری را وارد کنید', 'Enter a username') : null),
        TextFormField(controller: password, obscureText: true,
          decoration: InputDecoration(labelText: widget.existing == null
              ? tr('رمز عبور', 'Password') : tr('رمز عبور (خالی = بدون تغییر)', 'Password (blank = unchanged)')),
          validator: (v) => widget.existing == null && (v == null || v.isEmpty)
            ? tr('رمز عبور را وارد کنید', 'Enter a password') : null),
        TextFormField(controller: database,
          decoration: const InputDecoration(labelText: 'Initial Database')),
        if (testing) const LinearProgressIndicator(),
        if (testMessage != null) Padding(padding: const EdgeInsets.all(8), child: SelectableText(testMessage!)),
        OutlinedButton.icon(onPressed: testing ? null : testConnection, icon: const Icon(Icons.wifi_tethering),
          label: Text(tr('تست اتصال', 'Test connection'))),
        const SizedBox(height: 12),
        Wrap(spacing: 10, children: [
          for (final c in const [0xff3867d6, 0xff229d85, 0xffd06a3b,
            0xff9446b1, 0xffda4267, 0xff6b7582])
            InkWell(onTap: () => setState(() => colorValue = c),
              child: CircleAvatar(backgroundColor: Color(c), radius: 17,
                child: c == colorValue ? const Icon(Icons.check, size: 18) : null)),
        ]),
        const SizedBox(height: 10),
        if (picture != null) TextButton(onPressed: () => setState(() => picture = null), child: Text(tr('حذف عکس', 'Remove image'))),
        OutlinedButton.icon(onPressed: pickImage, icon: const Icon(Icons.image_outlined),
          label: Text(picture == null ? tr('انتخاب عکس سرور', 'Choose server image') : tr('تغییر عکس', 'Change image'))),
      ]),
    ))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('انصراف', 'Cancel'))),
      FilledButton(onPressed: testing ? null : () {
        if (!form.currentState!.validate()) return;
        final p = profile();
        Navigator.pop(context, EditedServer(p, password.text.isEmpty ? null : password.text));
      }, child: Text(tr('ذخیره', 'Save'))),
    ],
  );
}

