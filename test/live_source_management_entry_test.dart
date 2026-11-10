import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';

void main() {
  testWidgets('empty live page opens live-filtered sources without enabling them', (tester) async {
    LivePageState.debugLiveGroupsFetcher = () async => [];
    final commands = <String>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      commands.add(command);
      return switch(command) {
        'list_providers' => [
          {'id':'live', 'name':'直播示例', 'kind':'m3u_live', 'enabled':false, 'capabilities':{'live':true}},
          {'id':'vod', 'name':'点播示例', 'kind':'js', 'enabled':true, 'capabilities':{'vod':true}},
        ],
        'source_catalog_get' => {'origins':[], 'groups':[]},
        'source_discovery_status' => <String,dynamic>{},
        _ => throw StateError(command),
      };
    };
    addTearDown(() {
      LivePageState.debugLiveGroupsFetcher = null;
      SourinCore.debugCallAsyncTransport = null;
      SourceDiscoveryService.current.value = null;
    });
    final theme = AppTheme.themeFor(Brightness.light);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      theme:theme, builder:(_, child)=>AppThemeHost(data:theme, child:child!),
      home: Scaffold(body: Builder(builder:(context)=>LivePage(onManageSources:() async {
        opened++;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>SourceManagerPage(
          initialType:ManagedSourceType.live,
          onSourcesChanged:(){}, onImportTvbox:()async{}, onPasteJs:()async{},
          onEditProvider:(_)async{}, onConfigureProvider:(_)async{}, onRemoveProvider:(_)async{},
        )));
      }))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('没有可用的直播源'), findsOneWidget);
    expect(find.text('管理直播源'), findsOneWidget);
    await tester.tap(find.text('管理直播源'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byKey(const ValueKey('managed-source-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('managed-source-vod')), findsNothing);
    expect(commands.where((c)=>c.startsWith('set_') || c.contains('import')), isEmpty);
    Navigator.of(tester.element(find.byType(SourceManagerPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SourceManagerPage), findsNothing);
    expect(find.text('没有可用的直播源'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds:2));
  });
}
