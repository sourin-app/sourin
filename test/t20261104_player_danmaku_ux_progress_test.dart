import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_session.dart';

const _episodes = [
  Episode(id: 'e1', title: 'Episode One'),
  Episode(id: 'e2', title: 'Episode Two'),
];

MediaPlaybackProgress _progress({
  int generation = 1, String episode = 'e2', int position = 120,
  String id = 'work',
}) => MediaPlaybackProgress(
  provider: 'fixture', id: id, generation: generation,
  episodeId: episode,
  episodeTitle: episode == 'e1' ? 'Episode One' : 'Episode Two',
  position: Duration(seconds: position), duration: const Duration(seconds: 600),
);

Future<GlobalKey<State<DetailPage>>> _mount(
  WidgetTester tester, ValueNotifier<MediaPlaybackProgress?> progress,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final key = GlobalKey<State<DetailPage>>();
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: DetailPage(
    key: key, provider: 'fixture', id: 'work', embedded: true,
    currentEpisodeId: 'e2', playbackProgress: progress,
  ))));
  await tester.pump();
  (key.currentState! as dynamic).debugSetDetail(
    const MediaDetail(id: 'work', title: 'Work', episodes: _episodes),
    episodes: _episodes,
  );
  (key.currentState! as dynamic).debugSetResume(const Progress(
    key: 'opaque', provider: 'fixture', nativeId: 'work', title: 'Work',
    episodeId: 'e1', episodeTitle: 'Episode One', position: 60, duration: 600,
  ));
  await tester.pump();
  return key;
}

void main() {
  testWidgets('right detail observes current episode and seek without reload',
    (tester) async {
      final progress = ValueNotifier<MediaPlaybackProgress?>(null);
      addTearDown(progress.dispose);
      await _mount(tester, progress);
      expect(find.text('Episode One'), findsWidgets);
      progress.value = _progress();
      await tester.pump();
      final text = find.text('Episode Two');
      expect(text, findsNWidgets(2),
        reason: 'Episode title must appear in real resume chip and episode row');
      expect(find.textContaining('剩 8 分钟'), findsOneWidget);
      progress.value = _progress(position: 480);
      await tester.pump();
      expect(find.textContaining('剩 2 分钟'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      progress.value = _progress(position: 500);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

  testWidgets('older session and foreign work cannot replace current progress',
    (tester) async {
      final progress = ValueNotifier<MediaPlaybackProgress?>(null);
      addTearDown(progress.dispose);
      await _mount(tester, progress);
      progress.value = _progress(generation: 3, position: 480);
      await tester.pump();
      progress.value = _progress(generation: 2, episode: 'e1', position: 120);
      await tester.pump();
      expect(find.textContaining('剩 2 分钟'), findsOneWidget);
      progress.value = _progress(generation: 4, id: 'foreign', position: 300);
      await tester.pump();
      expect(find.textContaining('剩 2 分钟'), findsOneWidget);
      progress.value = _progress(generation: 4, position: 0);
      await tester.pump();
      expect(find.text('上次看到 '), findsNothing,
        reason: 'Changing episodes does not mark it as watched or finished');
    });
}
