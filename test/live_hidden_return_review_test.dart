import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_live_guard_fixture.dart';

void main() {
  testWidgets(
    'membership refresh while fullscreen must not resolve hidden embedded stream',
    verifyRefreshDuringFullscreenOwnsNoStream,
  );
  testWidgets(
    'shell ordered visible refresh preserves deferred playing channel once',
    (t) => verifyShellOrderedVisibleRefresh(t, playing: true),
  );
  testWidgets(
    'shell ordered visible refresh preserves deferred paused channel once',
    (t) => verifyShellOrderedVisibleRefresh(t, playing: false),
  );
  testWidgets(
    'visibility during returned playing snapshot restoration stays owned',
    (t) => verifyVisibleDuringReturnMetadata(t, playing: true),
  );
  testWidgets(
    'visibility during returned paused snapshot restoration stays owned',
    (t) => verifyVisibleDuringReturnMetadata(t, playing: false),
  );
}
