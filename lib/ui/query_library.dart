import 'package:flutter/material.dart';
import '../data/query_repository.dart';
import 'app_settings.dart';

class QueryLibrary extends StatefulWidget {
  const QueryLibrary({super.key, required this.repository, required this.serverNames});
  final QueryRepository repository;
  final Map<String, String> serverNames;
  @override
  State<QueryLibrary> createState() => _QueryLibraryState();
}
class _QueryLibraryState extends State<QueryLibrary> {
  bool saved = false;
  String search = '';
  late Future<List<Map<String, dynamic>>> entries = widget.repository.entries(saved);
  void reload() => setState(() => entries = widget.repository.entries(saved));
  @override
  Widget build(BuildContext context) => SafeArea(child: Padding(
    padding: const EdgeInsets.all(16), child: Column(children: [
      SegmentedButton<bool>(segments: [
        ButtonSegment(value: false, icon: const Icon(Icons.history), label: Text(tr('تاریخچه', 'History'))),
        ButtonSegment(value: true, icon: const Icon(Icons.bookmarks_outlined), label: Text(tr('ذخیره‌شده‌ها', 'Saved'))),
      ], selected: {saved}, onSelectionChanged: (v) { saved = v.first; reload(); }),
      const SizedBox(height: 12),
      TextField(onChanged: (v) => setState(() => search = v.toLowerCase()), decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search), hintText: tr('جستجوی عنوان یا SQL', 'Search title or SQL'))),
      Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: entries, builder: (context, state) {
        if (state.hasError) return Center(child: SelectableText('${state.error}'));
        if (!state.hasData) return const Center(child: CircularProgressIndicator());
        final items = state.data!.where((e) => '${e['title']} ${e['sql']} ${e['database']}'.toLowerCase().contains(search)).toList();
        if (items.isEmpty) return Center(child: Text(tr('کوئری‌ای وجود ندارد.', 'No queries yet.')));
        return ListView.builder(itemCount: items.length, itemBuilder: (context, i) {
          final entry = items[i];
          final server = widget.serverNames[entry['serverId']];
          final date = DateTime.tryParse('${entry['at']}')?.toLocal();
          return Card(child: ListTile(
            leading: Icon(saved ? Icons.bookmark_outline : entry['success'] == true ? Icons.check_circle_outline : Icons.error_outline),
            title: Text('${entry['title'] ?? entry['sql']}', maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${server ?? tr('سرور حذف شده', 'Removed server')} / ${entry['database']}\n'
              '${date?.toString().split('.').first ?? ''}${saved ? '' : ' · ${entry['elapsedMs']} ms'}'),
            isThreeLine: true, onTap: server == null ? null : () => Navigator.pop(context, entry),
            trailing: IconButton(tooltip: tr('حذف', 'Delete'), icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                try { await widget.repository.remove('${entry['id']}', saved: saved); if (mounted) reload(); }
                catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
              }),
          ));
        });
      })),
    ]),
  ));
}
