import 'package:flutter_test/flutter_test.dart';
import 'package:odin_sql/data/sql_manager.dart';

void main() {
  test('SQL identifiers use escaped brackets', () {
    expect(quoteIdentifier('Accountings'), '[Accountings]');
    expect(quoteIdentifier('Sales]2026'), '[Sales]]2026]');
  });
}
