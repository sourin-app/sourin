import 'package:sourin_spike/core/models.dart';

const followProgressFixture = Progress(
  key: 'fixture:continue:e2',
  provider: 'fixture',
  nativeId: 'continue',
  title: '继续观看示例',
  episodeId: 'e2',
  episodeTitle: '第 2 集',
  position: 40,
  duration: 100,
);

/// Replaces native transport while preserving the real page's loading,
/// deserialization, tab refresh, card rendering and detail callback paths.
Future<dynamic> followFixtureTransport(
  String command,
  Map<String, dynamic>? args,
) async => switch (command) {
  'continue_watching' ||
  'list_all_progress' => [followProgressFixture.toJson()],
  'list_favorites' ||
  'list_following_for_ui' ||
  'list_providers' ||
  'check_updates' => <dynamic>[],
  'total_unread' || 'repair_library_covers' => 0,
  'continue_watching_count' => 1,
  _ => throw UnsupportedError('Unexpected fixture command: $command'),
};
