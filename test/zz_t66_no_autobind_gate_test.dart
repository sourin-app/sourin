// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 Owner 第 6 条：弹幕**不许**自动绑定，只能手动
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// > 我看到 dan-api 提供的弹幕了,但是所有的弹幕
// > (除了插件自身提供的该视频的弹幕除外) 都应该手动绑定,而不是自动
// ```
//
// # 这一组守什么
// ```text
// ① 播放页的**起播路径**里不许再出现「自动发起绑定搜索」的调用
// ② `autoBindBySearch` 函数**必须还在** —— 它要给手动入口用
//    （删掉函数是过度删除，会把手动绑定一起弄坏）
// ③ 手动入口必须可达（弹幕面板里有搜索/绑定入口）
// ```
//
// # 为什么用源码契约断言
// ```text
// 起播路径要真跑需要 media_kit（libmpv-2.dll），在 flutter_tester 里
// 会偶发 native 崩溃（见 dart_test.yaml 顶部与 test/t72_jank_test.dart）。
// ⇒ 用源码契约锁住「调用点消失 / 函数仍在」，再由真机验行为。
//
// ⚠️ 这类断言的价值完全取决于「能否变红」：
//    把 `if (_danmakuEnabled && biliBind == null) { await _autoBindBili(); }`
//    加回去 ⇒ 第 ① 条必须立刻红。已在交付说明里附注入读数。
// ```
//
// # 判在**剥注释后**的文本上
// ```text
// 播放页里那段改动说明的注释**引用**了 `_autoBindBili()` 这个名字
// （解释"改前是什么"）。若判原文，注释一写就假红。
// ⇒ 必须先剥注释再判。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 Dart 源码里的块注释与行注释（简单实现，对本仓库足够）
///
/// ⚠️ 不做完整的词法分析（不需要）：本文件只判「某个调用形态在不在」，
///    正则剥注释足以覆盖，且不会误伤字符串里的 `//`（本文件只搜标识符）。
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  group('Owner 第 6 条：弹幕必须手动绑定，不许自动', () {
    late String code;

    setUpAll(() {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      code = _stripComments(src);
    });

    test('★★★ 起播路径里**不许**出现「自动发起绑定搜索」的调用', () {
      /*
       * 改前的那段（本轮删除）：
       * ```dart
       * if (_danmakuEnabled && biliBind == null) {
       *   final ok = await _autoBindBili();
       *   if (ok) return;
       * }
       * ```
       * 判据：剥注释后，`await _autoBindBili()` 这个**调用形态**必须不存在。
       *
       * ⚠️ 只判 `_autoBindBili`（方法名）不够 —— 方法**定义**里当然有它。
       *    所以判的是 `await _autoBindBili(` 这个调用点。
       */
      expect(
        code.contains('await _autoBindBili('),
        isFalse,
        reason: '★★★ 起播时不许自动发起绑定搜索 —— '
            'Owner 第 6 条要求「都应该手动绑定,而不是自动」。'
            '★ 这条一旦红，说明有人把自动绑定加回来了',
      );
    });

    test('★★ `autoBindBySearch` 与 `_autoBindBili` **必须还在**（手动入口要用）', () {
      /*
       * 反向守卫：只删调用点、**不许连函数一起删**。
       * 删了函数 ⇒ 手动绑定入口也一起坏掉 —— 那是过度删除。
       */
      expect(
        code.contains('Future<bool> _autoBindBili('),
        isTrue,
        reason: '★★ `_autoBindBili` 必须保留 —— 手动入口还要用它',
      );
      final bind = File('lib/core/bili/bili_bind.dart').readAsStringSync();
      expect(
        bind.contains('autoBindBySearch('),
        isTrue,
        reason: '★★ autoBindBySearch 本身要留着（它是有用能力，只是不再自动调）',
      );
    });

    test('★★ 手动绑定入口存在（弹幕面板里有搜索/绑定）', () {
      /*
       * Owner 说「都应该手动绑定」⇒ 那就**必须**有手动的地方。
       * 若把自动删了却没手动入口，等于把功能整体拿掉 —— 那是另一种交付缺陷。
       */
      final dialog = File('lib/ui/widgets/danmaku_settings_dialog.dart')
          .readAsStringSync();
      final dialogCode = _stripComments(dialog);
      expect(
        dialogCode.contains('search') || dialogCode.contains('Search'),
        isTrue,
        reason: '★★ 弹幕面板里必须有搜索入口（手动绑定的起点）',
      );
    });
  });
}
