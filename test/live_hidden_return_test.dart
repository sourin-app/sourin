import 'package:flutter_test/flutter_test.dart';

import 'support/legacy_live_guard_fixture.dart';

void main() {
  testWidgets(
    'hidden switched return keeps playing intent and loads on visibility',
    (tester) => verifyHiddenSwitchedReturn(tester, playing: true),
  );
  testWidgets(
    'hidden switched return keeps paused muted intent and loads on visibility',
    (tester) => verifyHiddenSwitchedReturn(tester, playing: false),
  );
  testWidgets(
    'visible switched playing return remains a working control',
    verifyVisibleSwitchedPlayingReturn,
  );
  testWidgets(
    'visible switched paused return remains a working control',
    verifyLegacyFullscreenChannelIntent,
  );
  testWidgets(
    'newer hidden explicit selection supersedes deferred fullscreen target',
    verifyHiddenReturnNewerSelectionWins,
  );
}
