import 'package:flutter/foundation.dart';

import 'ui_prefs.dart';

enum AppLogoStyle {
  orbit('01-orbit', '源环'),
  frames('02-frames', '叠映'),
  current('03-current', '流光'),
  screen('04-screen', '映窗');

  const AppLogoStyle(this.id, this.label);
  final String id;
  final String label;
  String get imageAsset => 'assets/logos/$id.png';
  String get windowsAsset => 'assets/logos/$id.ico';
}

abstract final class AppLogoPreference {
  static const key = 'dsh.appearance.logo';
  static final current = ValueNotifier<AppLogoStyle>(AppLogoStyle.orbit);

  static void load() {
    final stored = UiPrefs.get(key);
    current.value = AppLogoStyle.values.firstWhere(
      (style) => style.id == stored,
      orElse: () => AppLogoStyle.orbit,
    );
  }

  static void select(AppLogoStyle style) {
    UiPrefs.set(key, style.id);
    current.value = style;
  }
}
