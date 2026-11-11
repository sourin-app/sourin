// Runtime checks observe the initial/retry and channel-return command paths.
import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_live_guard_fixture.dart';

void main() {
  testWidgets(
    'fullscreen channel adoption preserves returned playback intent',
    verifyLegacyFullscreenChannelIntent,
  );
  testWidgets(
    'both embedded open paths respect playback intent before starting',
    (tester) async {
      await verifyLegacyInitialOpenIntent(tester);
      await verifyLegacyPendingPauseDuringRetry(tester);
      await verifyLegacyFullscreenChannelIntent(tester);
    },
  );
}
