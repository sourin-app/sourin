import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_live_guard_fixture.dart';

void main() {
  testWidgets(
    'removed fullscreen member selects exact fallback without embedded resolve',
    verifyFullscreenMembershipRemovedFallback,
  );
  testWidgets(
    'empty groups keep removed media stopped after playing return',
    (t) => verifyFullscreenMembershipEmpty(t, playing: true, emptyGroups: true),
  );
  testWidgets(
    'empty channel array keeps removed media stopped after paused return',
    (t) =>
        verifyFullscreenMembershipEmpty(t, playing: false, emptyGroups: false),
  );
  testWidgets(
    'restored fullscreen member adopts the refreshed channel object',
    verifyFullscreenMembershipRestoresCurrentObject,
  );
}
