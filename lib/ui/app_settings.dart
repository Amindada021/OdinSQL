import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

final appSettings = AppSettings();
String tr(String fa, String en) => appSettings.persian ? fa : en;

class AppSettings extends ChangeNotifier {
  ThemeMode theme = ThemeMode.dark;
  bool persian = true;
  double fontSize = 14;
  int timeoutSeconds = 30;
  bool allowLegacyTlsLogin = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    theme = ThemeMode.values[p.getInt('theme')?.clamp(0, 2).toInt() ?? 2];
    persian = p.getBool('persian') ?? true;
    fontSize = (p.getDouble('editorFont') ?? 14).clamp(10, 24).toDouble();
    timeoutSeconds = (p.getInt('queryTimeout') ?? 30).clamp(5, 600).toInt();
    allowLegacyTlsLogin = p.getBool('allowLegacyTlsLogin') ?? false;
  }

  Future<void> save() async {
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt('theme', theme.index);
    await p.setBool('persian', persian);
    await p.setDouble('editorFont', fontSize);
    await p.setInt('queryTimeout', timeoutSeconds);
    await p.setBool('allowLegacyTlsLogin', allowLegacyTlsLogin);
  }
}

ThemeData studioTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff6688ff), brightness: brightness,
    surface: dark ? const Color(0xff171c28) : const Color(0xfff7f8fc),
  );
  return ThemeData(
    useMaterial3: true, colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xff10141f) : const Color(0xffeef1f8),
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, centerTitle: false),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: scheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    navigationBarTheme: const NavigationBarThemeData(height: 68),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: .5)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Future<void> showStudioSettings(BuildContext context) => showModalBottomSheet<void>(
  context: context, isScrollControlled: true, showDragHandle: true,
  builder: (context) => StatefulBuilder(builder: (context, refresh) {
    void update(VoidCallback change) {
      change();
      appSettings.save().catchError((Object e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); });
      refresh(() {});
    }
    return SafeArea(child: SingleChildScrollView(child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('تنظیمات محیط', 'Studio settings'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        SegmentedButton<ThemeMode>(segments: [
          ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode_outlined), label: Text(tr('روشن', 'Light'))),
          ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode_outlined), label: Text(tr('تیره', 'Dark'))),
          ButtonSegment(value: ThemeMode.system, icon: const Icon(Icons.brightness_auto_outlined), label: Text(tr('سیستم', 'System'))),
        ], selected: {appSettings.theme}, onSelectionChanged: (v) => update(() => appSettings.theme = v.first)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فارسی / English'),
          value: appSettings.persian, onChanged: (v) => update(() => appSettings.persian = v)),
        Text('${tr('اندازه فونت SQL', 'SQL font size')}: ${appSettings.fontSize.round()}'),
        Slider(min: 10, max: 24, divisions: 14, value: appSettings.fontSize,
          onChanged: (v) => update(() => appSettings.fontSize = v)),
        Text(tr('مهلت اجرای کوئری (ثانیه)', 'Query timeout (seconds)')),
        DropdownButton<int>(value: appSettings.timeoutSeconds,
          items: [for (final v in {5, 15, 30, 60, 120, 300, 600, appSettings.timeoutSeconds})
            DropdownMenuItem(value: v, child: Text('$v'))],
          onChanged: (v) { if (v != null) update(() => appSettings.timeoutSeconds = v); }),
        const Divider(height: 32),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('سازگاری TLS قدیمی (ناامن)', 'Legacy TLS login compatibility (unsafe)')),
          subtitle: Text(tr(
            'فقط برای SQL Server قدیمی بدون TLS 1.2. این تنظیم امنیت Handshake تمام سرورهای برنامه را کاهش می‌دهد و بعد از بستن کامل و بازکردن اپ اعمال می‌شود.',
            'Only for unpatched old SQL Servers. Weakens login handshake security for ALL server connections in this app. Fully restart the app after changing.',
          )),
          value: appSettings.allowLegacyTlsLogin,
          onChanged: (enabled) async {
            if (enabled) {
              final accept = await showDialog<bool>(context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text(tr('هشدار امنیتی', 'Security warning')),
                  content: Text(tr(
                    'قبل از فعال‌سازی ابتدا دسترسی TCP و نسخه SQL Server را بررسی کنید. این گزینه TLS 1.0 و تنظیمات امنیتی ضعیف‌تر را برای تمام اتصال‌های OdinSQL فعال می‌کند. فقط در شبکه امن/VPN و برای سرور قدیمی استفاده کنید.',
                    'First verify TCP reachability and SQL Server version. This enables TLS 1.0 and weaker handshake settings process-wide for all OdinSQL connections. Use only on a trusted network/VPN with an old server.',
                  )),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(tr('انصراف', 'Cancel'))),
                    FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(tr('می‌پذیرم', 'I understand'))),
                  ],
                ));
              if (accept != true || !context.mounted) return;
            }
            update(() => appSettings.allowLegacyTlsLogin = enabled);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:
                Text(tr('برای اعمال، برنامه را کامل ببندید و دوباره اجرا کنید.',
                  'Fully close and restart the app to apply the change.'))));
            }
          },
        ),
      ]),
    )));
  }),
);
