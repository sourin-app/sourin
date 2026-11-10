// 新增入口仅提供 TVBox；共享编排器继续供 JS 覆盖层使用。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';

void main() {
  testWidgets('TVBox 新增入口不再打开声明式编排器', (tester) async {
    final theme = AppTheme.themeFor(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => ui.TextButton(
              onPressed: () => ProviderImportDialog.showAdd(context),
              child: const Text('打开导入'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
    expect(find.text('导入 TVBox 配置'), findsOneWidget);
    expect(find.text('导入并探测'), findsOneWidget);
    expect(find.text('可视化编排'), findsNothing);
    expect(find.text('填入模板'), findsNothing);
    expect(find.byType(SourceComposerDialog), findsNothing);
    expect(find.byType(ui.TextField), findsNWidgets(3));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ProviderImportDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
