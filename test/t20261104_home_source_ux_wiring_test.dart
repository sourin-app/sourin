import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'home configuration lives only in settings, not either home toolbar',
    () {
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      final web = File('lib/ui/webhome/webhome_page.dart').readAsStringSync();
      final settings = File('lib/ui/settings_page.dart').readAsStringSync();
      expect(home.contains('child: WebHomeEntryButton()'), isFalse);
      expect(
        home.contains('onOpenSettings: () => showWebHomeSettingsSheet'),
        isFalse,
      );
      expect(web.contains('onTap: widget.onOpenSettings'), isFalse);
      expect(settings.contains('WebHomeSettingsPage('), isTrue);
    },
  );

  test('source management exposes search, state, import and ordering', () {
    final settings = File('lib/ui/settings_page.dart').readAsStringSync();
    expect(
      settings.contains("ValueKey<String>('source-manager-search')"),
      isTrue,
    );
    expect(settings.contains('filterManagedSources('), isTrue);
    expect(
      settings.contains("ValueKey<String>('source-manager-import')"),
      isTrue,
    );
    expect(
      settings.contains("ValueKey<String>('source-manager-order')"),
      isTrue,
    );
    expect(
      settings.contains('_dataRev.value++'),
      isTrue,
      reason: 'filters must refresh the pushed route, not only its host',
    );
  });

  test(
    'aggregate filtering and bulk selection retain nonvisible selections',
    () {
      final source = File('lib/ui/settings/tvbox_aggregate_page.dart')
          .readAsStringSync();
      expect(source.contains("ValueKey<String>('agg-sites-search')"), isTrue);
      expect(
        source.contains("ValueKey<String>('agg-sites-select-visible')"),
        isTrue,
      );
      expect(
        source.contains("ValueKey<String>('agg-sites-clear-visible')"),
        isTrue,
      );
      expect(source.contains('filterManagedSites('), isTrue);
    },
  );
}
