import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mssql_native/mssql_native.dart';
import 'app_settings.dart';

Object? resultValue(MssqlResultSet set, int row, int column) => set.typedRows.isNotEmpty
  ? set.typedRows[row].at(column) : set.rows[row][set.columns[column].name];
String displayValue(Object? value) {
  if (value == null) return 'NULL';
  if (value is Uint8List) return '0x${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  if (value is DateTime) return value.toIso8601String();
  return value.toString();
}
Object? jsonValue(Object? value) => value == null || value is String || value is bool || value is int
  ? value : value is double && value.isFinite ? value : displayValue(value);

class ResultPane extends StatefulWidget {
  const ResultPane({super.key, required this.result, this.error, this.elapsed});
  final MssqlExecutionResult? result;
  final String? error;
  final Duration? elapsed;
  @override
  State<ResultPane> createState() => _ResultPaneState();
}

class _ResultPaneState extends State<ResultPane> {
  int selected = 0;
  bool exporting = false;
  @override
  void didUpdateWidget(covariant ResultPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) selected = 0;
  }
  Future<void> export(MssqlResultSet set, String format) async {
    if (exporting) return;
    setState(() => exporting = true);
    try {
      final columns = set.columns.map((c) => c.name).toList();
      late String content;
      if (format == 'json') {
        // A column array and ordinal rows retain duplicate SQL column labels.
        content = const JsonEncoder.withIndent('  ').convert({
          'columns': columns,
          'rows': [for (var r = 0; r < set.rows.length; r++)
            [for (var c = 0; c < columns.length; c++) jsonValue(resultValue(set, r, c))]],
        });
      } else {
        String csv(Object? value) => value == null ? '' : '"${displayValue(value).replaceAll('"', '""')}"';
        final out = StringBuffer('\uFEFF')..writeln(columns.map(csv).join(','));
        for (var r = 0; r < set.rows.length; r++) {
          out.write([for (var c = 0; c < columns.length; c++) csv(resultValue(set, r, c))].join(','));
          out.write('\r\n');
        }
        content = out.toString();
      }
      final bytes = Uint8List.fromList(utf8.encode(content));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: tr('ذخیره نتیجه', 'Save result'),
        fileName: 'OdinSQL_${DateTime.now().millisecondsSinceEpoch}.$format',
        type: FileType.custom, allowedExtensions: [format], bytes: bytes,
      );
      if (path != null) {
        if (!Platform.isAndroid && !Platform.isIOS) await File(path).writeAsBytes(bytes, flush: true);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('فایل ذخیره شد.', 'File saved.'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally { if (mounted) setState(() => exporting = false); }
  }
  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final sets = result?.resultSets ?? <MssqlResultSet>[];
    final index = selected.clamp(0, sets.length);
    final set = index < sets.length ? sets[index] : null;
    return Column(children: [
      SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, children: [
        for (var i = 0; i < sets.length; i++) Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ChoiceChip(label: Text('${tr('نتیجه', 'Result')} ${i + 1} · ${sets[i].rows.length}'), selected: index == i,
            onSelected: (_) => setState(() => selected = i))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: ChoiceChip(label: Text(tr('پیام‌ها', 'Messages')),
          selected: set == null, onSelected: (_) => setState(() => selected = sets.length))),
        if (set != null) PopupMenuButton<String>(tooltip: tr('خروجی', 'Export'), enabled: !exporting,
          icon: exporting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.file_download_outlined),
          onSelected: (format) => export(set, format), itemBuilder: (_) => const [
            PopupMenuItem(value: 'csv', child: Text('Export CSV')), PopupMenuItem(value: 'json', child: Text('Export JSON')),
          ]),
      ])),
      Expanded(child: set != null ? ResultGrid(key: ValueKey(set), result: set) : SingleChildScrollView(
        padding: const EdgeInsets.all(12), child: Align(alignment: AlignmentDirectional.topStart, child: SelectableText([
          if (widget.error != null) widget.error!,
          if (result != null) '${tr('ردیف‌های تحت تأثیر', 'Affected rows')}: ${result.affectedRows}',
          if (widget.elapsed != null) '${tr('مدت اجرا', 'Elapsed')}: ${widget.elapsed!.inMilliseconds} ms',
          if (result != null) for (final m in result.messages) '${m.number} · ${m.severity} · ${tr('خط', 'Line')} ${m.line}: ${m.message}',
          if (result != null && result.messages.isEmpty && widget.error == null) tr('اجرا تکمیل شد.', 'Execution completed.'),
          if (result == null && widget.error == null) tr('کوئری را اجرا کنید تا نتیجه اینجا نمایش داده شود.', 'Execute a query to see results here.'),
        ].join('\n'), style: TextStyle(fontFamily: 'monospace', color: widget.error == null ? null : Theme.of(context).colorScheme.error))),
      )),
      Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text('${widget.elapsed?.inMilliseconds ?? 0} ms · ${result?.affectedRows ?? 0} ${tr('ردیف متأثر', 'affected')} · '
          '${tr('حد نتیجه: ۱۰٬۰۰۰ ردیف / ۳۲MB', 'Result limit: 10,000 rows / 32MB')}',
          style: Theme.of(context).textTheme.labelSmall)),
    ]);
  }
}

class ResultGrid extends StatefulWidget {
  const ResultGrid({super.key, required this.result});
  final MssqlResultSet result;
  @override
  State<ResultGrid> createState() => _ResultGridState();
}
class _ResultGridState extends State<ResultGrid> {
  final horizontal = ScrollController(), vertical = ScrollController();
  @override
  void dispose() { horizontal.dispose(); vertical.dispose(); super.dispose(); }
  void inspect(Object? value) => showDialog<void>(context: context, builder: (context) => AlertDialog(
    title: Text(value == null ? 'NULL' : tr('مقدار سلول', 'Cell value')),
    content: SizedBox(width: 500, child: SingleChildScrollView(child: SelectableText(displayValue(value)))),
    actions: [TextButton.icon(onPressed: () { Clipboard.setData(ClipboardData(text: displayValue(value))); Navigator.pop(context); },
      icon: const Icon(Icons.copy, size: 18), label: Text(tr('کپی', 'Copy')))],
  ));
  @override
  Widget build(BuildContext context) {
    final set = widget.result;
    if (set.columns.isEmpty) return Center(child: Text(tr('بدون ستون', 'No columns')));
    final scheme = Theme.of(context).colorScheme;
    return Directionality(textDirection: TextDirection.ltr, child: LayoutBuilder(builder: (context, bounds) =>
      Scrollbar(controller: horizontal, thumbVisibility: true, notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(controller: horizontal, scrollDirection: Axis.horizontal,
          child: SizedBox(width: 56 + set.columns.length * 180.0, height: bounds.maxHeight,
            child: Column(children: [
              Container(height: 40, color: scheme.surfaceContainerHighest, child: Row(children: [
                const SizedBox(width: 56, child: Center(child: Text('#'))),
                for (final c in set.columns) Container(width: 180, padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(border: BorderDirectional(start: BorderSide(color: scheme.outlineVariant))),
                  child: Tooltip(message: c.name, child: Text(c.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)))),
              ])),
              Expanded(child: Scrollbar(controller: vertical, child: ListView.builder(controller: vertical,
                itemExtent: 44, itemCount: set.rows.length, itemBuilder: (context, r) => Container(
                  decoration: BoxDecoration(color: r.isEven ? scheme.surface : scheme.surfaceContainerLow,
                    border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35)))),
                  child: Row(children: [
                    SizedBox(width: 56, child: Center(child: Text('${r + 1}', style: TextStyle(color: scheme.outline)))),
                    for (var c = 0; c < set.columns.length; c++) Builder(builder: (context) {
                      final value = resultValue(set, r, c);
                      return InkWell(onTap: () => inspect(value),
                        onLongPress: () {
                          Clipboard.setData(ClipboardData(text: displayValue(value)));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('کپی شد', 'Copied'))));
                        }, child: Container(width: 180, alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35)))),
                          child: Text(displayValue(value), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontStyle: value == null ? FontStyle.italic : null, color: value == null ? scheme.outline : null))));
                    }),
                  ]),
                )))),
            ]),
          ),
        ),
      ),
    ));
  }
}
