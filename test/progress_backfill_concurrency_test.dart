import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/progress_backfill.dart';

// The real backfill and merge functions run here. Only detail/save I/O is
// replaced. These cases establish frontend record preservation, not database
// atomicity, live source metadata or native rendering.
const _oldCover = 'https://media.invalid/old-cover.jpg';
const _newCover = 'https://media.invalid/new-cover.jpg';
const _detailTitle = '目录作品';

Progress _record({
  String title = '',
  String? cover = _oldCover,
  String? episodeTitle,
  String? episodeId = 'episode-a',
  int position = 45,
  int duration = 1800,
  bool finished = false,
  int updatedAt = 100,
}) => Progress(
  key: 'opaque-episode-key',
  provider: 'fixture-provider',
  nativeId: 'fixture-work',
  title: title,
  cover: cover,
  episodeId: episodeId,
  episodeTitle: episodeTitle,
  position: position,
  duration: duration,
  finished: finished,
  updatedAt: updatedAt,
);

class _DelayedDetail {
  final detail = Completer<MediaDetail>();
  final requested = <(String, String)>[];
  final saved = <({Progress record, String title, String? cover})>[];

  late final backfill = ProgressTitleBackfill(
    fetchDetail: (provider, id) {
      requested.add((provider, id));
      return detail.future;
    },
    saveProgress: (record, {required title, cover}) async {
      saved.add((record: record, title: title, cover: cover));
    },
  );

  void complete({String? cover = _oldCover}) {
    detail.complete(MediaDetail(
      id: 'fixture-work',
      title: _detailTitle,
      cover: cover,
    ));
  }
}

void main() {
  test('delayed title backfill retains playback fields refreshed while waiting',
      () async {
    final fixture = _DelayedDetail();
    var current = [_record()];
    final pending = fixture.backfill.backfill(current);
    expect(fixture.requested, [('fixture-provider', 'fixture-work')]);
    expect(fixture.saved, isEmpty);

    // The list reloads a newer row while the real detail future is pending.
    current = [_record(
      position: 1998,
      duration: 2000,
      finished: true,
      episodeTitle: '第1集',
      updatedAt: 200,
    )];
    fixture.complete();
    final patched = await pending;
    expect(fixture.saved, hasLength(1));
    expect(fixture.saved.single.title, _detailTitle);
    final merged = mergeBackfilled(current, patched).single;

    expect(merged.title, _detailTitle);
    expect(merged.position, 1998,
        reason: 'Metadata arriving late must not rewind current playback');
    expect(merged.duration, 2000);
    expect(merged.finished, isTrue);
    expect(merged.episodeId, 'episode-a');
    expect(merged.episodeTitle, '第1集');
    expect(merged.updatedAt, 200);
  });

  test('delayed title backfill retains a newer repaired cover', () async {
    final fixture = _DelayedDetail();
    var current = [_record()];
    final pending = fixture.backfill.backfill(current);
    expect(fixture.requested, [('fixture-provider', 'fixture-work')]);

    // A background cover repair reloads the exact same record during fetch.
    // Cover repair deliberately keeps ordering timestamps unchanged.
    current = [_record(cover: _newCover)];
    fixture.complete();
    final patched = await pending;
    expect(fixture.saved, hasLength(1));
    final merged = mergeBackfilled(current, patched).single;

    expect(merged.title, _detailTitle);
    expect(merged.cover, _newCover,
        reason: 'A stale detail cover must not undo the already repaired URL');
    expect(merged.updatedAt, 100);
  });

  test('unchanged records still receive the fetched title and missing cover',
      () async {
    final fixture = _DelayedDetail();
    final current = [_record(cover: null)];
    final pending = fixture.backfill.backfill(current);
    fixture.complete(cover: _newCover);
    final merged = mergeBackfilled(current, await pending).single;

    expect(fixture.requested, [('fixture-provider', 'fixture-work')]);
    expect(fixture.saved, hasLength(1));
    expect(fixture.saved.single.cover, _newCover);
    expect(merged.title, _detailTitle);
    expect(merged.cover, _newCover);
    expect(merged.position, 45);
    expect(merged.duration, 1800);
    expect(merged.finished, isFalse);
    expect(merged.updatedAt, 100);
  });

  test('a record removed during detail fetch is not reinserted by merge',
      () async {
    final fixture = _DelayedDetail();
    final pending = fixture.backfill.backfill([_record()]);
    final current = <Progress>[];
    fixture.complete();
    final patched = await pending;

    expect(patched, hasLength(1), reason: 'The late real backfill must finish');
    expect(mergeBackfilled(current, patched), isEmpty);
  });

  test('title and cover compare their captured fields independently', () async {
    final fixture = _DelayedDetail();
    final pending = fixture.backfill.backfill([_record()]);
    final current = [_record(title: '较新的标题')];
    fixture.complete(cover: _newCover);
    final merged = mergeBackfilled(current, await pending).single;

    expect(merged.title, '较新的标题');
    expect(merged.cover, _newCover,
        reason: 'An unchanged cover can update even when the title changed');
    expect(merged.updatedAt, 100);
  });

  test('an empty fetched cover does not erase existing artwork', () async {
    final fixture = _DelayedDetail();
    final current = [_record()];
    final pending = fixture.backfill.backfill(current);
    fixture.complete(cover: '   ');
    final merged = mergeBackfilled(current, await pending).single;

    expect(merged.title, _detailTitle);
    expect(merged.cover, _oldCover);
  });

  test('the default saver sends only the conditional metadata contract',
      () async {
    final previous = SourinCore.debugCallAsyncTransport;
    addTearDown(() => SourinCore.debugCallAsyncTransport = previous);
    final calls = <({String command, Map<String, dynamic> args})>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(args, isNotNull, reason: 'Metadata writes require their payload');
      calls.add((command: command, args: Map<String, dynamic>.from(args!)));
      return <String, dynamic>{};
    };
    final backfill = ProgressTitleBackfill(
      fetchDetail: (_, __) async => const MediaDetail(
        id: 'fixture-work', title: _detailTitle, cover: _newCover,
      ),
    );
    final patches = await backfill.backfill([
      _record(title: '   ', cover: null, episodeId: null),
    ]);

    expect(patches, hasLength(1));
    expect(calls, hasLength(1));
    expect(calls.single.command, 'patch_progress_metadata');
    expect(calls.single.args, {
      'provider': 'fixture-provider',
      'id': 'fixture-work',
      'episode_id': null,
      'expected_title': '   ',
      'expected_cover': null,
      'title': _detailTitle,
      'cover': _newCover,
    }, reason: 'Metadata repair must not send playback or ordering fields');
  });
}
