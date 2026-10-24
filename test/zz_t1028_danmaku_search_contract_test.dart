import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings delegates search and bounds its entire content', () {
    final source = File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
    expect(source, contains('final VoidCallback? onOpenSearch;'));
    expect(source, contains('danmaku-settings-scroll'));
    final start = source.indexOf('final settings =');
    final build = source.substring(start, source.indexOf('final body =', start));
    expect(build, isNot(contains('_group(_requestSection())')));
    expect(build, isNot(contains('_group(_searchSection())')));
    expect(build, isNot(contains('_group(_errorSection(s.error!))')));
  });
}
