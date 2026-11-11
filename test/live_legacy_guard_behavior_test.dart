// Independent runtime inputs, before any migration of the old source/cast guards.
// No decoder, real user profile, source account or desktop is accessed.
import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_live_guard_fixture.dart';

void main() {
  testWidgets(
    'initial retry respects accepted pause before native autoplay',
    verifyLegacyInitialOpenIntent,
  );
  testWidgets(
    'pending user pause protects an awaited initial retry open',
    verifyLegacyPendingPauseDuringRetry,
  );
  testWidgets(
    'fullscreen channel return preserves paused muted snapshot and provider',
    verifyLegacyFullscreenChannelIntent,
  );
  testWidgets(
    'fullscreen query step and pick select without embedded resolution or playback',
    verifyLegacyFullscreenSelectionOnly,
  );
  testWidgets(
    'real Miuix mute slider restores remembered volume after snapshot',
    verifyLegacyRenderedMuteRestore,
  );
}
