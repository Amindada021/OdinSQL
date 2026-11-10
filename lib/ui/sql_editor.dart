import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_settings.dart';

const sqlKeywords = <String>{
  'SELECT','FROM','WHERE','JOIN','LEFT','RIGHT','INNER','OUTER','FULL','CROSS','ON','AS',
  'INSERT','INTO','VALUES','UPDATE','SET','DELETE','MERGE','USING','WHEN','MATCHED',
  'CREATE','ALTER','DROP','TRUNCATE','TABLE','VIEW','PROCEDURE','FUNCTION','INDEX',
  'EXEC','EXECUTE','DECLARE','BEGIN','END','IF','ELSE','RETURN','WHILE','TRY','CATCH',
  'ORDER','BY','GROUP','HAVING','TOP','DISTINCT','UNION','ALL','WITH','AND','OR','NOT',
  'NULL','IS','IN','EXISTS','LIKE','BETWEEN','CASE','THEN','ASC','DESC','OFFSET','FETCH',
  'INT','BIGINT','BIT','VARCHAR','NVARCHAR','DECIMAL','DATETIME','DATE','CAST','CONVERT',
  'COUNT','SUM','AVG','MIN','MAX','ISNULL','COALESCE','GETDATE','USE','GO',
  'TRANSACTION','COMMIT','ROLLBACK','BACKUP','RESTORE','GRANT','DENY','REVOKE',
};

// SQL Server supports nested block comments and doubled quote/bracket escapes.
// Never reflow or change the contents of these tokens.
Iterable<String> tokenizeSql(String source) sync* {
  var i = 0;
  bool word(String c) {
    final n = c.codeUnitAt(0);
    return n >= 48 && n <= 57 || n >= 65 && n <= 90 || n >= 97 && n <= 122 || c == '_' || c == '#' || c == r'$';
  }
  while (i < source.length) {
    final start = i;
    if (source.startsWith('--', i)) {
      i += 2;
      while (i < source.length && source[i] != '\n' && source[i] != '\r') { i++; }
    } else if (source.startsWith('/*', i)) {
      i += 2;
      var depth = 1;
      while (i < source.length && depth > 0) {
        if (source.startsWith('/*', i)) { depth++; i += 2; }
        else if (source.startsWith('*/', i)) { depth--; i += 2; }
        else { i++; }
      }
    } else if (source[i] == "'" || source[i] == '[' || source[i] == '"' ||
        ((source[i] == 'N' || source[i] == 'n') && i + 1 < source.length && source[i + 1] == "'")) {
      if ((source[i] == 'N' || source[i] == 'n') && source[i + 1] == "'") i++;
      final close = source[i] == '[' ? ']' : source[i];
      i++;
      while (i < source.length) {
        if (source[i] == close) {
          i++;
          if (i < source.length && source[i] == close) { i++; }
          else { break; }
        } else { i++; }
      }
    } else if (source[i].trim().isEmpty) {
      do { i++; } while (i < source.length && source[i].trim().isEmpty);
    } else if (word(source[i]) || source[i] == '@') {
      do { i++; } while (i < source.length && (word(source[i]) || source[i] == '@'));
    } else { i++; }
    yield source.substring(start, i);
  }
}

String formatSql(String input) {
  final matches = tokenizeSql(input).toList();
  final out = StringBuffer();
  var depth = 0;
  for (var i = 0; i < matches.length; i++) {
    final token = matches[i];
    if (token == '(') depth++;
    if (token == ')') depth = math.max(0, depth - 1);
    if (token.trim().isEmpty && depth == 0 && i + 1 < matches.length &&
        const {'FROM','WHERE','GROUP','ORDER','HAVING','UNION','SET','VALUES'}.contains(matches[i + 1].toUpperCase())) {
      out.write('\n');
    } else {
      out.write(token);
    }
  }
  return out.toString();
}

class SqlEditingController extends TextEditingController {
  SqlEditingController({super.text});
  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextSpan(style: style, children: [for (final token in tokenizeSql(text))
      TextSpan(text: token, style: TextStyle(color: colorFor(token, dark))) ]);
  }
  Color? colorFor(String token, bool dark) {
    if (token.startsWith('--') || token.startsWith('/*')) return dark ? const Color(0xff7fa77c) : const Color(0xff4c7649);
    if (token.startsWith("'") || token.startsWith("N'") || token.startsWith("n'")) return dark ? const Color(0xffe6ad8e) : const Color(0xff9b492e);
    if (token.startsWith('@')) return dark ? const Color(0xffcaa8ee) : const Color(0xff7948a5);
    if (sqlKeywords.contains(token.toUpperCase())) return dark ? const Color(0xff87b5ff) : const Color(0xff2459b0);
    if (RegExp(r'^\d').hasMatch(token)) return dark ? const Color(0xffa6d5aa) : const Color(0xff347342);
    return null;
  }
}

class SqlEditor extends StatefulWidget {
  const SqlEditor({super.key, required this.controller, required this.undo,
    required this.suggestions, required this.readOnly});
  final SqlEditingController controller;
  final UndoHistoryController undo;
  final List<String> suggestions;
  final bool readOnly;
  @override
  State<SqlEditor> createState() => _SqlEditorState();
}

class _SqlEditorState extends State<SqlEditor> {
  final vertical = ScrollController();
  final horizontal = ScrollController();
  final focus = FocusNode();
  @override
  void initState() {
    super.initState(); widget.controller.addListener(changed); vertical.addListener(changed);
  }
  void changed() { if (mounted) setState(() {}); }
  @override
  void dispose() {
    widget.controller.removeListener(changed);
    vertical.dispose(); horizontal.dispose(); focus.dispose(); super.dispose();
  }
  String get prefix {
    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return '';
    return RegExp(r'[A-Za-z_][A-Za-z_0-9]*$').firstMatch(
      widget.controller.text.substring(0, selection.baseOffset))?.group(0) ?? '';
  }
  void complete(String word) {
    final c = widget.controller;
    final end = c.selection.baseOffset, start = c.selection.baseOffset - prefix.length;
    c.value = TextEditingValue(text: c.text.replaceRange(start, end, word),
      selection: TextSelection.collapsed(offset: start + word.length));
    focus.requestFocus();
  }
  @override
  Widget build(BuildContext context) {
    final lines = widget.controller.text.split('\n');
    final font = appSettings.fontSize;
    final lineHeight = font * 1.6;
    final longest = lines.fold<int>(0, (n, line) => math.max(n, line.replaceAll('\t', '    ').length));
    final p = prefix.toLowerCase();
    final candidates = p.isEmpty || widget.readOnly || (MediaQuery.orientationOf(context) == Orientation.landscape && MediaQuery.viewInsetsOf(context).bottom > 0) ? <String>[] :
      {...widget.suggestions, ...sqlKeywords}.where((s) => s.toLowerCase().startsWith(p) && s.toLowerCase() != p).take(10).toList();
    return Column(children: [
      Expanded(child: Directionality(textDirection: TextDirection.ltr, child: LayoutBuilder(builder: (context, constraints) =>
        ClipRect(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 48, color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Stack(children: [Positioned(top: 12 - (vertical.hasClients ? vertical.offset : 0), left: 0, right: 6,
              child: Text(List.generate(lines.length, (i) => '${i + 1}').join('\n'), textAlign: TextAlign.right,
                style: TextStyle(fontFamily: 'monospace', fontSize: font, height: 1.6, color: Theme.of(context).colorScheme.outline)))])),
          Expanded(child: Scrollbar(controller: horizontal, child: SingleChildScrollView(controller: horizontal, scrollDirection: Axis.horizontal,
            child: SizedBox(width: math.max(constraints.maxWidth - 48, longest * font + 60), height: constraints.maxHeight,
              child: TextField(controller: widget.controller, undoController: widget.undo, focusNode: focus,
                readOnly: widget.readOnly, scrollController: vertical, expands: true, minLines: null, maxLines: null,
                autocorrect: false, enableSuggestions: false, smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled, keyboardType: TextInputType.multiline,
                textDirection: TextDirection.ltr, textAlignVertical: TextAlignVertical.top,
                style: TextStyle(fontFamily: 'monospace', fontSize: font, height: lineHeight / font),
                decoration: const InputDecoration(filled: false, border: InputBorder.none,
                  enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.all(12), hintText: 'SELECT TOP (100) * FROM [dbo].[MyTable];'),
              ))))),
        ])),
      ))),
      if (candidates.isNotEmpty) SizedBox(height: 36, child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final word in candidates) Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
          child: ActionChip(label: Text(word), onPressed: () => complete(word))),
      ])),
    ]);
  }
}
