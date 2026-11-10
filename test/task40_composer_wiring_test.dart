// 声明式编辑退役后，HTTP 编辑和 JS 个性化覆盖仍保留。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _code(String path) => File(path).readAsStringSync().replaceAll(
  RegExp(r'/\*[\s\S]*?\*/|//[^\n]*'),
  '',
);

void main() {
  final settings = _code('lib/ui/settings_page.dart');
  final importDialog = _code('lib/ui/widgets/provider_import_dialog.dart');

  test('声明式编辑、保存与文本回退入口已删除', () {
    expect(settings, isNot(contains('_editDeclarativeViaComposer')));
    expect(settings, isNot(contains('_openDeclarativeTextFallback')));
    expect(settings, isNot(contains('importDeclarativeProvider(')));
    expect(importDialog, isNot(contains('importDeclarativeProvider(')));
    expect(importDialog, isNot(contains('ImportMode.declarative')));
  });

  test('JS 编辑仍打开源码编辑器', () {
    final start = settings.indexOf('Future<void> _editProvider(');
    final body = settings.substring(start, settings.indexOf('Future<void> _afterImport(', start));
    expect(body, contains("if (p.kind == 'js')"));
    expect(body, contains('await _editPlugin(info);'));
    expect(body, contains("if (p.kind != 'http')"));
  });

  test('JS 无配置项时仍打开仅覆盖层的共享编排器', () {
    final start = settings.indexOf('Future<void> _configPlugin(');
    final body = settings.substring(start, settings.indexOf('int get _enabledCount', start));
    expect(body, contains('SourceComposerDialog('));
    expect(body, contains('overridesTargetId: e.id'));
    expect(body, contains('overridesSourceName: e.name'));
    expect(body, contains('overridesOnly: true'));
  });

  test('HTTP 历史配置仍可回填并保存', () {
    expect(settings, contains('ProviderImportDialog.showEdit('));
    expect(settings, contains('seed == null || !seed.isHttp'));
    expect(importDialog, contains('SourinApi.installHttpProvider('));
    expect(importDialog, contains('parseHeaders(_headersCtl.text)'));
  });
}
