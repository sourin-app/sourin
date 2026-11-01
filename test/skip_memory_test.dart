// ═══════════════════════════════════════════════════════════════════════
//  T7 记忆式片头 —— 分类器行为门禁 + 消费链接线（源码结构门禁）
// ═══════════════════════════════════════════════════════════════════════
//
// # 分层
// ```text
// ① 纯函数判据（classifyIntroMemorySeek）—— 全部边界，脱离播放器可测；
// ② 消费链接线 —— 源码结构断言（_loadSkipMarker 换命令、_seekByUser 挂钩、
//    开关缺省关），与 skip_marker_test.dart 的源码门禁同一手法。
// ```
// # 硬要求（Lead 批复 A/B）
// ```text
// A. 声明已设 intro_end 的条目，用户再怎么 seek 都不落库
//    ⇒ 用例组「声明优先」（纯函数首条短路 + Rust 库级兜底各有单测）。
// B. seek 90s（合格）→ 回 20s → 150s ⇒ 最终 intro_end=150，
//    中间那次不合格的不落库 ⇒ 用例「收敛语义」。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/skip_memory.dart';

// 复用 zz_t1024 的"剥注释保留换行"工具（同一手法，不复制一份造成两套真相）
import 'zz_t1024_skip_respects_user_seek_test.dart' as zz
    show stripCommentsKeepLines;

void main() {
  group('classifyIntroMemorySeek · 记入', () {
    test('从 0 前跳到 90s ⇒ 记 intro_end=90（硬要求 B 的第一步）', () {
      final d = classifyIntroMemorySeek(
        from: Duration.zero,
        to: const Duration(seconds: 90),
        duration: const Duration(seconds: 1420),
      );
      expect(d, const Duration(seconds: 90));
    });

    test('出发点放宽到 max(90s, 片长5%)：40 分钟片上限是 120s（5% > 90s）', () {
      final d = classifyIntroMemorySeek(
        from: const Duration(seconds: 110), // 40min=2400s，5%=120s ⇒ 上限 120s
        to: const Duration(seconds: 170),
        duration: const Duration(minutes: 40),
      );
      expect(d, const Duration(seconds: 170), reason: '110 ≤ max(90,120)=120 ⇒ 算片头疑似区');

      expect(
        classifyIntroMemorySeek(
          from: const Duration(seconds: 150), // 150 > 120 ⇒ 已出片头疑似区
          to: const Duration(seconds: 200),
          duration: const Duration(minutes: 40),
        ),
        isNull,
      );
    });

    test('长片 5% 阈值生效：2 小时片从 5 分钟处前跳也算片头疑似区', () {
      // 2h=7200s，5%=360s > 90s ⇒ 上限 360s
      final d = classifyIntroMemorySeek(
        from: const Duration(seconds: 350),
        to: const Duration(seconds: 420),
        duration: const Duration(hours: 2),
      );
      expect(d, const Duration(seconds: 420));
    });

    test('会话内已记同值 ⇒ 静默（不重写、不重复打扰）', () {
      final d = classifyIntroMemorySeek(
        from: Duration.zero,
        to: const Duration(seconds: 90),
        duration: const Duration(seconds: 1420),
        memoryIntroEnd: 90,
      );
      expect(d, isNull);
    });
  });

  group('classifyIntroMemorySeek · 不记（宁可少记，不可乱记）', () {
    test('★ 互检 P2-1：记忆已存在 ⇒ 仍可被新 seek 修正（不许跨会话冻结）', () {
      // 记忆=90，新 seek 落点 150 ⇒ 必须允许覆盖（修正语义）
      expect(
        classifyIntroMemorySeek(
          from: const Duration(seconds: 20),
          to: const Duration(seconds: 150),
          duration: const Duration(seconds: 1420),
          memoryIntroEnd: 90,
        ),
        const Duration(seconds: 150),
        reason: '★ 记忆来源的值必须允许被覆盖；声明的拦截在 Rust 库级，'
            '分类器若把生效值当声明短路 = 记忆冻结（互检 P2-1）',
      );
    });

    test('片长未知（0）⇒ 不记', () {
      expect(
        classifyIntroMemorySeek(
          from: Duration.zero,
          to: const Duration(seconds: 90),
          duration: Duration.zero,
        ),
        isNull,
      );
    });

    test('出发点在正片中段 ⇒ 不记（从 200s 拖走不是片头信号）', () {
      expect(
        classifyIntroMemorySeek(
          from: const Duration(seconds: 200),
          to: const Duration(seconds: 260),
          duration: const Duration(seconds: 1420),
        ),
        isNull,
      );
    });

    test('回跳 / 原地 ⇒ 不记（用户想重看）', () {
      expect(
        classifyIntroMemorySeek(
          from: const Duration(seconds: 90),
          to: const Duration(seconds: 20),
          duration: const Duration(seconds: 1420),
        ),
        isNull,
      );
      expect(
        classifyIntroMemorySeek(
          from: const Duration(seconds: 90),
          to: const Duration(seconds: 90),
          duration: const Duration(seconds: 1420),
        ),
        isNull,
      );
    });

    test('微调（< 30s）⇒ 不记', () {
      expect(
        classifyIntroMemorySeek(
          from: Duration.zero,
          to: const Duration(seconds: 20),
          duration: const Duration(seconds: 1420),
        ),
        isNull,
      );
    });

    test('落点超过 600s ⇒ 不记（更像跳到想看的剧情；那种需求走显式声明）', () {
      expect(
        classifyIntroMemorySeek(
          from: Duration.zero,
          to: const Duration(seconds: 601),
          duration: const Duration(seconds: 7200),
        ),
        isNull,
      );
    });

    test('★ 互检 P3-1：落点超过片长 50% ⇒ 不记（短片防整片跳过）', () {
      // 5 分钟短片（300s）：50% = 150s < 600s ⇒ 相对上限生效
      expect(
        classifyIntroMemorySeek(
          from: Duration.zero,
          to: const Duration(seconds: 151),
          duration: const Duration(minutes: 5),
        ),
        isNull,
        reason: '★ 151s > 300s×50%：把 5 分钟短片"记 2.5 分钟片头"= 整片跳过',
      );
      // 相对上限以内照记
      expect(
        classifyIntroMemorySeek(
          from: Duration.zero,
          to: const Duration(seconds: 100),
          duration: const Duration(minutes: 5),
        ),
        const Duration(seconds: 100),
      );
    });
  });

  group('★ 硬要求 B：收敛语义（最后一次合格 seek 为准）', () {
    test('seek 90s（合格）→ 回 20s（不落库）→ 150s（合格）⇒ 最终 150', () {
      const dur = Duration(seconds: 1420);
      int? remembered;

      // 第一步：0 → 90，合格 ⇒ 记 90
      final s1 = classifyIntroMemorySeek(
        from: Duration.zero,
        to: const Duration(seconds: 90),
        duration: dur,
        memoryIntroEnd: remembered,
      );
      expect(s1, const Duration(seconds: 90));
      remembered = s1!.inSeconds;

      // 第二步：90 → 20（回跳），不合格 ⇒ **不落库**（remembered 保持 90）
      final s2 = classifyIntroMemorySeek(
        from: const Duration(seconds: 90),
        to: const Duration(seconds: 20),
        duration: dur,
        memoryIntroEnd: remembered,
      );
      expect(s2, isNull, reason: '回跳不产生写入');
      expect(remembered, 90);

      // 第三步：20 → 150，合格 ⇒ 覆盖为 150（最后一次合格为准）
      final s3 = classifyIntroMemorySeek(
        from: const Duration(seconds: 20),
        to: const Duration(seconds: 150),
        duration: dur,
        memoryIntroEnd: remembered,
      );
      expect(s3, const Duration(seconds: 150));
      remembered = s3!.inSeconds;

      expect(remembered, 150, reason: '★ 最终 intro_end=150');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  消费链接线（源码结构门禁 —— 与 skip_marker_test.dart 同手法）
  // ══════════════════════════════════════════════════════════════════
  group('接线门禁（player_page 源码结构）', () {
    final src =
        File('lib/ui/player_page.dart').readAsStringSync();
    // 剥注释后的实码（键名/调用出现在注释里不算接线）
    final code = zz.stripCommentsKeepLines(src);

    test('★ 互检 P1-1：关 = 读纯声明，开 = 读生效值（读侧分流，不只是拦写侧）', () {
      expect(code.contains('? await SourinApi.getEffectiveSkipMarker'), isTrue,
          reason: '★ 开（记忆启用）⇒ 读生效值（声明 ⊕ 记忆）');
      expect(code.contains(': await SourinApi.getSkipMarker'), isTrue,
          reason: '★★★ 关（默认）⇒ 读纯声明 get_skip_marker —— '
              '只拦写侧时"开→记住→关"后照样跳（记忆行还在），关必须连读侧一起关');
    });

    test('★ 互检 P2-1：挂钩不得把生效值当声明传入（记忆必须可修正）', () {
      final hook = _fnBody(code, 'void _rememberIntroFromUserSeek(Duration target)');
      expect(hook.contains('declaredIntroEnd'), isFalse,
          reason: '★★★ 分类器不得收 declared 短路 —— _skipMarker 是合并后的生效值，'
              '记忆来源的字段被当声明 ⇒ 记忆跨会话冻结。声明的拦截在 Rust 库级');
    });

    test('★ 互检 P2-2：flash 必须等写库结果，被拦（false）不出', () {
      final hook = _fnBody(code, 'void _rememberIntroFromUserSeek(Duration target)');
      expect(hook.contains('.then((ok)'), isTrue,
          reason: '★ 必须消费 setSkipMemory 的返回值');
      expect(hook.contains('if (!ok) return;'), isTrue,
          reason: '★★★ false = 被声明优先拦截 ⇒ 不出 flash（sourin_api 文档纪律）');
    });

    test('★ 互检 P1-2：「继续观看」与远端预览抑制记忆（落点不是片头信号）', () {
      final rewatch = _fnBody(code, 'void continueFromRewatchPrompt()');
      final seekAt = rewatch.indexOf('_seekByUser(pos)');
      final supAt = rewatch.indexOf('_suppressMemorySeekOnce = true;');
      expect(seekAt, greaterThan(-1), reason: '★ rewatch 仍须走 _seekByUser（zz_t1024 门禁）');
      expect(supAt, greaterThan(-1), reason: '★★★ rewatch 必须抑制记忆挂钩 '
          '（from≈0、to=上次位置 ⇒ 必然误记成片头终点 = 静默吃内容）');
      expect(supAt, lessThan(seekAt),
          reason: '★ 抑制位必须在 seek **之前**置位（挂钩在 _seekByUser 同步段执行）');
      // 远端 skip_preview（手机微调、电视出画面）：预览位置同样不是意图
      final preview = _caseBody(code, "case 'skip_preview':");
      expect(preview.contains('_suppressMemorySeekOnce = true;'), isTrue,
          reason: '★ 预览路径同样抑制（用户多半在标声明，记记忆纯添乱）');
    });

    test('记忆挂钩只挂在 _seekByUser 内（六条用户路径唯一汇聚点）', () {
      expect(code.contains('_rememberIntroFromUserSeek(target);'), isTrue,
          reason: '★ _seekByUser 内必须挂钩（自动跳过是 programmatic seek，不进这里 ⇒ 无回写环）');
    });

    test('总开关缺省关（UX 底线①：不开记忆就不跳）', () {
      expect(src.contains("bool _skipMemoryEnabled = false;"), isTrue,
          reason: '★ 字段缺省 false');
      expect(src.contains("UiPrefs.get('dsh.playprefs.skipMemory') == '1'"), isTrue,
          reason: '★ 读偏好用 == \'1\'（键不存在 ⇒ 关），不是 != \'0\' 那种缺省开的写法');
    });

    test('记忆动作有可见反馈（UX 底线②：不许静默改用户数据）', () {
      expect(src.contains("'已记住片头到"), isTrue, reason: '★ 命中必须 _flash');
      expect(src.contains("'记忆片头终点"), isTrue, reason: '★ 必须落 AppLog（Release 可排查）');
    });

    test('三条换集/换源清理路都清 _memoryIntroEnd（换键后去重判据不得跨集）', () {
      // 换源(_applySwitch) / 换会话(applySession) / 切集(_gotoEpisode)
      expect('_memoryIntroEnd = null;'.allMatches(src).length, greaterThanOrEqualTo(3),
          reason: '★ 三条生产清理路 + 探针，至少 3 处');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  面板接线门禁（批复裁定②）：开关必须**真接** skipMemory 键，
  //  不许"画了个摆设"。剥注释断言 —— 注释里提到键名不算接线。
  // ══════════════════════════════════════════════════════════════════
  group('面板接线门禁（player_settings_sheet）', () {
    final pageCode = zz.stripCommentsKeepLines(
        File('lib/ui/player_page.dart').readAsStringSync());
    final sheetCode = zz.stripCommentsKeepLines(
        File('lib/ui/widgets/player_settings_sheet.dart').readAsStringSync());

    test('面板真的画了开关行（与 autoSkip 同区块同组件）', () {
      // 剥注释后仍命中 ⇒ 是**实码**，不是文档里的引用
      expect(sheetCode.contains("'记忆式跳过片头'"), isTrue,
          reason: '★ 开关行必须在 _switchRow 里真的画出来');
      expect(sheetCode.contains('widget.skipMemoryEnabled'), isTrue,
          reason: '★ 行的值必须来自宿主传入的 skipMemoryEnabled（不是写死的假值）');
      expect(sheetCode.contains('widget.onSetSkipMemory!'), isTrue,
          reason: '★ 行的回调必须是 onSetSkipMemory 本身');
      expect(sheetCode.contains('记忆式：拖过片头自动记住（可在设置清除）'), isTrue,
          reason: '★ 说明文案按批复：写清"记忆式"与"可清除"');
    });

    test('开关真接了 skipMemory 键（面板回调真的落库，不是摆设）', () {
      expect(pageCode.contains('onSetSkipMemory: (v)'), isTrue,
          reason: '★ 面板构造点必须传 onSetSkipMemory（不传 ⇒ 行不画 = 没接）');
      expect(pageCode.contains("_savePlayPref('skipMemory'"), isTrue,
          reason: '★★★ 面板回调必须真的写 dsh.playprefs.skipMemory（_savePlayPref 会加前缀）——'
              '只画开关不落库 = 摆设');
      expect(pageCode.contains("UiPrefs.get('dsh.playprefs.skipMemory')"), isTrue,
          reason: '★ 读偏好也必须是这个键（写读不同键 = 永远关）');
      expect(pageCode.contains('skipMemoryEnabled: _skipMemoryEnabled'), isTrue,
          reason: '★ 面板显示值必须来自生产字段 _skipMemoryEnabled');
    });
  });
}

/// 按**大括号配平**切出函数体（与 zz_t1024 的 `_dartFnBody` 同法；
/// 不能 import 它 —— 那是私有函数，复制一份比把两套门禁焊死强不了多少，
/// 但这里必须作用于**剥注释后**的实码，与 zz 的原码用法不同）。
String _fnBody(String code, String signature) {
  final at = code.indexOf(signature);
  expect(at, greaterThan(-1), reason: '锚点不存在：$signature');
  final open = code.indexOf('{', at);
  expect(open, greaterThan(-1), reason: '`$signature` 后面必须有 `{`');
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(at, i + 1);
    }
  }
  fail('`$signature` 的大括号不配平');
}

/// 切出 switch 的一个 `case` 块（case 体没有花括号，按下一个 case 边界切）
String _caseBody(String code, String caseLabel) {
  final at = code.indexOf(caseLabel);
  expect(at, greaterThan(-1), reason: 'case 锚点不存在：$caseLabel');
  var next = code.indexOf('\n      case ', at);
  if (next < 0) next = code.indexOf('\n      default:', at);
  if (next < 0) next = code.length;
  return code.substring(at, next);
}
