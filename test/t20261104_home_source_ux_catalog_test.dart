import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/webhome/webhome_store.dart';

void main() {
  test(
    'named home templates persist, switch, edit and delete independently',
    () async {
      final dir = await Directory.systemTemp.createTemp('home-library-');
      addTearDown(() async {
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
      WebHomeController.debugSetDataDir(dir.path);
      await UiPrefs.load(dir.path);
      final dynamic controller = WebHomeController.instance;
      await controller.ensureLoaded();
      final dynamic first = await controller.saveTemplate(
        name: 'Movies',
        html: '<h1>Movies</h1>',
        activate: true,
      );
      final dynamic second = await controller.saveTemplate(
        name: 'Shows',
        html: '<h1>Shows</h1>',
      );
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first.id, isNot(second.id));
      expect(controller.templates.length, 2);
      expect(controller.activeId, first.id);
      expect(controller.html, '<h1>Movies</h1>');
      expect(await controller.activateTemplate(second.id), isTrue);
      expect(controller.html, '<h1>Shows</h1>');
      controller.reportLoadFailure('synthetic-load-failure');
      expect(
        await controller.saveTemplate(
          id: first.id,
          name: 'Cinema',
          html: '<h1>Cinema</h1>',
        ),
        isNotNull,
      );
      expect(
        controller.html,
        '<h1>Shows</h1>',
        reason: 'editing an inactive template must not switch the homepage',
      );
      expect(
        controller.fallbackThisSession,
        isTrue,
        reason:
            'editing another template must not reactivate a failed homepage',
      );
      expect(await controller.activateTemplate(second.id), isTrue);
      expect(controller.fallbackThisSession, isFalse);
      await controller.reload();
      expect(controller.templates.length, 2);
      expect(controller.activeId, second.id);
      expect(controller.showWebHome, isTrue);
      expect(await controller.deleteTemplate(second.id), isTrue);
      expect(controller.showWebHome, isFalse);
      expect(
        controller.activeId,
        isNull,
        reason: 'deleting the active template explicitly selects native',
      );
      await controller.reload();
      expect(controller.templates.length, 1);
      expect(controller.enabled, isFalse);
      expect(await controller.activateTemplate(first.id), isTrue);
      expect(controller.html, '<h1>Cinema</h1>');
      await controller.disable();
      await controller.reload();
      expect(controller.enabled, isFalse);
      expect(controller.templates.length, 1);
      expect(await controller.saveTemplate(name: '', html: '<p>x</p>'), isNull);
      expect(await controller.saveTemplate(name: 'Empty', html: ' '), isNull);
    },
  );

  test(
    'legacy single home migrates once without losing its original file',
    () async {
      final dir = await Directory.systemTemp.createTemp('home-legacy-');
      addTearDown(() async {
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
      final legacy = File('${dir.path}/webhome/home.html');
      await legacy.parent.create(recursive: true);
      await legacy.writeAsString('<h1>Legacy</h1>');
      WebHomeController.debugSetDataDir(dir.path);
      UiPrefs.debugResetForTest({webhomeEnabledKey: '1'});
      final dynamic controller = WebHomeController.instance;
      await controller.reload();
      expect(controller.templates.length, 1);
      expect(controller.html, '<h1>Legacy</h1>');
      expect(controller.showWebHome, isTrue);
      await controller.reload();
      expect(
        controller.templates.length,
        1,
        reason: 'migration must be idempotent',
      );
      expect(await legacy.readAsString(), '<h1>Legacy</h1>');
      final catalog = jsonDecode(
        await File('${dir.path}/webhome/library.json').readAsString(),
      );
      expect(catalog['version'], 2);
      expect(catalog['items'], hasLength(1));
      expect(await controller.saveAndEnable('<h1>Compatible</h1>'), isTrue);
      expect(controller.templates.length, 1);
      expect(
        await legacy.readAsString(),
        '<h1>Legacy</h1>',
        reason: 'legacy compatibility must not overwrite the migration source',
      );
    },
  );

  test(
    'a corrupt catalog is preserved rather than overwritten by a new save',
    () async {
      final dir = await Directory.systemTemp.createTemp('home-corrupt-');
      addTearDown(() async {
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
      final catalog = File('${dir.path}/webhome/library.json');
      await catalog.parent.create(recursive: true);
      await catalog.writeAsString('{corrupt-but-recoverable');
      WebHomeController.debugSetDataDir(dir.path);
      final dynamic controller = WebHomeController.instance;
      await controller.reload();
      expect(controller.showWebHome, isFalse);
      expect(
        await controller.saveTemplate(name: 'New', html: '<h1>New</h1>'),
        isNull,
      );
      expect(await catalog.readAsString(), '{corrupt-but-recoverable');
    },
  );

  test(
    'failed catalog commit preserves active content and removes the new body',
    () async {
      final dir = await Directory.systemTemp.createTemp('home-atomic-');
      addTearDown(() async {
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
      WebHomeController.debugSetDataDir(dir.path);
      final dynamic controller = WebHomeController.instance;
      await controller.reload();
      final dynamic original = await controller.saveTemplate(
        name: 'Original',
        html: '<h1>Original</h1>',
        activate: true,
      );
      final catalog = File('${dir.path}/webhome/library.json');
      final backup = await catalog.rename('${catalog.path}.backup');
      final savedCatalog = await backup.readAsString();
      final blocker = await Directory(catalog.path).create();
      expect(
        await controller.saveTemplate(
          id: original.id,
          name: 'Changed',
          html: '<h1>Changed</h1>',
          activate: true,
        ),
        isNull,
      );
      expect(controller.html, '<h1>Original</h1>');
      expect(controller.templates.single.name, 'Original');
      expect(await backup.readAsString(), savedCatalog);
      final bodies = await Directory('${dir.path}/webhome')
          .list()
          .where((file) => file.path.endsWith('.html'))
          .toList();
      expect(
        bodies,
        hasLength(1),
        reason: 'uncommitted template bodies must be removed',
      );
      await blocker.delete();
      await backup.rename(catalog.path);
      await controller.reload();
      expect(controller.html, '<h1>Original</h1>');
    },
  );

  test(
    'a missing active body can be repaired without discarding the library',
    () async {
      final dir = await Directory.systemTemp.createTemp('home-repair-');
      addTearDown(() async {
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
      WebHomeController.debugSetDataDir(dir.path);
      final controller = WebHomeController.instance;
      await controller.reload();
      final original = (await controller.saveTemplate(
        name: 'Original',
        html: '<h1>Original</h1>',
        activate: true,
      ))!;
      await File('${dir.path}/webhome/${original.file}').delete();
      await controller.reload();
      expect(controller.showWebHome, isFalse);
      expect(controller.templates.single.id, original.id);
      expect(
        await controller.saveTemplate(
          id: original.id,
          name: 'Repaired',
          html: '<h1>Repaired</h1>',
          activate: true,
        ),
        isNotNull,
        reason:
            'a valid catalog must remain editable when one body is unreadable',
      );
      await controller.reload();
      expect(controller.html, '<h1>Repaired</h1>');
      expect(controller.showWebHome, isTrue);
    },
  );

  test(
    'legacy preference write failure cannot roll back a committed template',
    () async {
      final dir = await Directory.systemTemp.createTemp('home-pref-failure-');
      addTearDown(() async {
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
      WebHomeController.debugSetDataDir(dir.path);
      UiPrefs.debugResetForTest();
      await UiPrefs.load(dir.path);
      await Directory('${dir.path}/ui-prefs.json').create();
      final controller = WebHomeController.instance;
      await controller.reload();
      final saved = await controller.saveTemplate(
        name: 'Committed',
        html: '<h1>Committed</h1>',
        activate: true,
      );
      expect(saved, isNotNull);
      expect(
        await File('${dir.path}/webhome/${saved!.file}').readAsString(),
        '<h1>Committed</h1>',
      );
      expect(controller.lastStorageError, isNull);
      await controller.reload();
      expect(controller.html, '<h1>Committed</h1>');
      expect(controller.showWebHome, isTrue);
    },
  );
}
