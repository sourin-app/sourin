import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_live_guard_fixture.dart';

void main() {
  testWidgets(
    'default retry still loads paused then plays',
    verifyLegacyDefaultRetryPlays,
  );
  testWidgets(
    'initial false policy loads without playing',
    verifyLegacyInitialPausedPolicy,
  );
  testWidgets(
    'new channel accepts fresh play intent after prior user pause',
    verifyLegacyNewChannelResetsPause,
  );
  testWidgets(
    'pause during channel open cancels automatic play',
    verifyLegacyPendingPauseDuringChannelOpen,
  );
  testWidgets(
    'hidden retry defers native open until visible',
    verifyLegacyHiddenRetryDefersOpen,
  );
}
