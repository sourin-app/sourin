// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮批次 D：直播页 —— 分组 v2（按频道）/ 频道搜索 / 三态加载
// ═══════════════════════════════════════════════════════════════════════
//
// # 覆盖 Owner 本批的三条要求（逐条对应下面的组）
// ```text
// ① 首次打开显示 0 个  →  ⑥ 三态（loading/failed/empty）必须分开
// ② 第二次等很久       →  ⑤ 磁盘快照（DiskCache 往返）
// ③ 分组要按频道选     →  ① v2 判据 / ② v1→v2 兜底 / ③ 编辑 UI 真的勾得上
// ④ 频道搜索           →  ④ liveChannelMatchesQuery 判据
// ```
//
// # 为什么判据层要抽成顶层纯函数（这是本仓的结构墙，别绕）
// ```text
// `LivePage._groups` **只由 FFI 填** ⇒ `flutter test` 里恒为空
// （见 `t48_live_page_all_channels_test.dart` 开头那段墙的说明）。
// ⇒ 整页层面喂不进频道数据 ⇒ 所有判据必须抽成能直接喂输入的纯函数，
//   否则测试只能"读源码字符串"，那是**假绿**（铁律不许）。
// ```

// ignore_for_file: prefer_const_constructors
//   ↑ 唯一一处例外：`hashCode 与 == 一致` 那条断言**必须**用非 const
//     构造两个不同对象，否则 Dart 会把常量字面量折叠成同一个 ⇒ 断言恒真。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/live_page.dart';

LiveGroup grp(String id, {List<LiveChannel> channels = const []}) =>
    LiveGroup(provider: id, providerName: id.toUpperCase(), channels: channels);

LiveChannel ch(String id, String name, {String? group}) =>
    LiveChannel(id: id, name: name, group: group);

LiveFlatEntry entry(String provider, String id, String name) =>
    (channel: ch(id, name), tag: provider.toUpperCase(), provider: provider);

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  ① v2 判据：分组成员 = **频道**（Owner 原话的直接落地）
  // ═════════════════════════════════════════════════════════════════════
  group('① liveGroupAllowsChannel —— 按频道分组', () {
    test('★ group == null（全部分组）⇒ 全部放行（逐字等于不筛）', () {
      expect(
        liveGroupAllowsChannel(
          {'常看': [const LiveChannelRef('iptv', '1')]},
          const {},
          null,
          'iptv',
          '1',
        ),
        isTrue,
      );
      // ★ 连"组里根本没有的频道"也放行 —— 这正是"全部分组"的语义
      expect(
        liveGroupAllowsChannel(
          {'常看': [const LiveChannelRef('iptv', '1')]},
          const {},
          null,
          'other',
          '999',
        ),
        isTrue,
      );
    });

    test('★★ 组里有 v2 数据 ⇒ 只放行**被勾选的那个频道**', () {
      final g = {
        '常看': [
          const LiveChannelRef('iptv', 'cctv1'),
          const LiveChannelRef('iptv', 'cctv5'),
        ],
      };
      expect(liveGroupAllowsChannel(g, {}, '常看', 'iptv', 'cctv1'), isTrue);
      expect(liveGroupAllowsChannel(g, {}, '常看', 'iptv', 'cctv5'), isTrue);
      // ★ 同一个源里**没被勾选**的频道必须被挡掉 —— 这是 Owner 要的核心
      expect(liveGroupAllowsChannel(g, {}, '常看', 'iptv', 'cctv13'), isFalse);
    });

    test('★★★ 同 id 不同源 ⇒ **不能**互相命中（(provider, id) 必须成对）', () {
      /*
       * 实测本机两个直播源都有 id 形如 `1` / `2` 的频道。
       * 若判据只看 channelId ⇒ 用户在 A 源勾了 `1`，
       * B 源的 `1` 也会被放进来（他没选过的台）。
       */
      final g = {
        '常看': [const LiveChannelRef('jia', '1')],
      };
      expect(liveGroupAllowsChannel(g, {}, '常看', 'jia', '1'), isTrue);
      expect(liveGroupAllowsChannel(g, {}, '常看', 'yi', '1'), isFalse,
          reason: '★★★ 频道 id 只在源内唯一 ⇒ 必须带 provider 一起判');
    });

    test('★★ 没有 v2、但有 v1（按源）⇒ 回落到「这个源的全部频道」', () {
      // 这是"老分组不静默失效"的唯一保证
      const v1 = {
        '老组': ['iptv'],
      };
      expect(liveGroupAllowsChannel(const {}, v1, '老组', 'iptv', '任意台'), isTrue,
          reason: '★ 老格式的语义就是"整个源都在组里"');
      expect(liveGroupAllowsChannel(const {}, v1, '老组', '别的源', '任意台'), isFalse);
    });

    test('★★★ v2 优先于 v1（同一组两套都有数据时以 v2 为准）', () {
      final g2 = {
        '常看': [const LiveChannelRef('iptv', 'cctv1')],
      };
      const g1 = {
        '常看': ['iptv'], // 老数据：整个源
      };
      expect(liveGroupAllowsChannel(g2, g1, '常看', 'iptv', 'cctv1'), isTrue);
      expect(liveGroupAllowsChannel(g2, g1, '常看', 'iptv', 'cctv5'), isFalse,
          reason: '★★★ v2 说了算 —— 否则用户勾掉的台会被老数据放回来');
    });

    test('★★ 组**不存在** ⇒ 全部放行（绝不筛成空）', () {
      // 与 v1 的 applyLiveSourceGroup 同一条兜底纪律：
      // 组没建过 / 刚被删掉 ⇒ 不能把列表筛空（用户会以为功能坏了）
      expect(liveGroupAllowsChannel(const {}, const {}, '不存在的组', 'a', 'b'), isTrue);
    });

    /*
     * ★★★ 2026-10-18 修正（Owner 真机投诉）
     *
     * > 我切换到我自建的 常用分组，下面的列表没变化，
     * > 我明明只添加了一个 却还是展示全部
     *
     * 真机磁盘：`live_source_groups = {"常看":[]}`、`live_channel_groups` 不存在。
     * 改前落到"空组 ⇒ 全部放行"⇒ 切过去仍是全部频道（正是投诉的现象）。
     *
     * ⇒ 「组**不存在**」与「组**存在但空**」必须分开：
     *    前者放行全部（兜底），后者如实筛空 + 由 UI 给空态文案。
     */
    test('★★★ 组**存在但是空组** ⇒ 一个都不放行（不再"全部放行"）', () {
      expect(
        liveGroupAllowsChannel(
          const {'空组': <LiveChannelRef>[]},
          const {},
          '空组',
          'a',
          'b',
        ),
        isFalse,
        reason: '★ 用户明确建了一个空组 ⇒ 他说的是"这一组没有东西"，'
            '偷偷放行全部会让他以为分组根本没生效',
      );
      expect(
        liveGroupAllowsChannel(const {}, const {'空组': <String>[]}, '空组', 'a', 'b'),
        isFalse,
        reason: '★★ 真机上的形态：v1 有组名、值是空列表、v2 整份缺失',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② liveChannelGroupMembers —— null 与空列表是**两件事**
  // ═════════════════════════════════════════════════════════════════════
  group('② liveChannelGroupMembers —— 区分"没有 v2 数据"与"空组"', () {
    test('★ 组不存在 ⇒ null（调用方据此回落到 v1）', () {
      expect(liveChannelGroupMembers(const {}, '常看'), isNull);
    });

    test('★ 空组 ⇒ 空列表（不是 null）', () {
      final r = liveChannelGroupMembers(const {'空组': <LiveChannelRef>[]}, '空组');
      expect(r, isNotNull);
      expect(r, isEmpty);
    });

    test('★ 有成员 ⇒ 原样返回（顺序保留）', () {
      final r = liveChannelGroupMembers({
        '常看': [
          const LiveChannelRef('b', '2'),
          const LiveChannelRef('a', '1'),
        ],
      }, '常看');
      expect(r!.map((e) => e.key).toList(), ['b\u00002', 'a\u00001']);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ③ LiveChannelRef 序列化（向前兼容的另一半）
  // ═════════════════════════════════════════════════════════════════════
  group('③ LiveChannelRef 存取', () {
    test('★ toJson 用短键 p/c（省体积，一个组几十项）', () {
      expect(const LiveChannelRef('iptv', 'cctv1').toJson(),
          {'p': 'iptv', 'c': 'cctv1'});
    });

    test('★★ 逐项宽松：坏项返回 null（调用方跳过，不让整份作废）', () {
      expect(LiveChannelRef.tryParse(null), isNull);
      expect(LiveChannelRef.tryParse('字符串'), isNull);
      expect(LiveChannelRef.tryParse({'p': 'iptv'}), isNull); // 缺 c
      expect(LiveChannelRef.tryParse({'c': 'cctv1'}), isNull); // 缺 p
      expect(LiveChannelRef.tryParse({'p': '', 'c': 'cctv1'}), isNull); // 空串
      expect(LiveChannelRef.tryParse({'p': 'iptv', 'c': ''}), isNull);
      expect(LiveChannelRef.tryParse({'p': 1, 'c': 2}), isNull); // 类型不对
      // ★ 正常的能解析出来
      expect(LiveChannelRef.tryParse({'p': 'iptv', 'c': 'cctv1'}),
          const LiveChannelRef('iptv', 'cctv1'));
    });

    test('★★ 相等性按 (provider, channelId) —— 去重/勾选都靠它', () {
      expect(const LiveChannelRef('a', '1'), const LiveChannelRef('a', '1'));
      expect(const LiveChannelRef('a', '1') == const LiveChannelRef('b', '1'),
          isFalse);
      expect(const LiveChannelRef('a', '1') == const LiveChannelRef('a', '2'),
          isFalse);
      /*
       * hashCode 必须与 == 一致（否则放进 Set 会重复 ⇒ 用户勾两次同一个台）。
       *
       * ⚠️ 两个值必须**运行时构造**（用变量），不能写字面量常量：
       *    常量字面量写两个一样的，Dart 会把它折叠成同一个对象 ⇒
       *    集合长度恒为 1，**无论 hashCode 对不对** —— 那是恒真断言（假绿）。
       *    （analyzer 的 `equal_elements_in_set` 就是在提示这一点。）
       */
      // ⚠️ 这三行**必须**用非 const 构造（见上面的理由）——
      //    analyzer 会建议加 const，但加了就把断言变成恒真。
      final a = LiveChannelRef('a', '${1}');
      final b = LiveChannelRef('a', '${1}');
      expect(identical(a, b), isFalse, reason: '确认是两个**不同对象**');
      expect({a, b}.length, 1,
          reason: '★★ hashCode 与 == 必须一致 —— 否则同一台会被勾两次');
      // 阴性对照：不同 provider 的两个必须占两格（证明集合真的在去重）
      expect({a, LiveChannelRef('b', '${1}')}.length, 2);
    });

    test('★★ UiPrefs 往返：存进去再读出来完全一致', () {
      UiPrefs.debugResetForTest();
      final src = {
        '常看': [
          const LiveChannelRef('iptv', 'cctv1'),
          const LiveChannelRef('douyu', '9999'),
        ],
        '空组': <LiveChannelRef>[],
      };
      UiPrefs.setLiveChannelGroups(src);
      final back = UiPrefs.liveChannelGroups();
      expect(back.keys.toList(), ['常看', '空组'], reason: '★ 组顺序要保留');
      expect(back['常看']!.map((e) => e.key).toList(),
          ['iptv\u0000cctv1', 'douyu\u00009999']);
      expect(back['空组'], isEmpty, reason: '★ 空组要保留（不是被丢掉）');
    });

    test('★★★ 逐键宽松：一个组坏了只丢那个组，别的照收', () {
      UiPrefs.debugResetForTest();
      // 直接塞一份"半坏"的 JSON（模拟用户手改坏了其中一个组）
      UiPrefs.set(UiPrefs.liveChannelGroupsKey,
          jsonEncode({
            '好的': [
              {'p': 'iptv', 'c': 'cctv1'},
            ],
            '坏的': '这不是列表',
            '半坏': [
              {'p': 'iptv', 'c': 'cctv5'},
              {'p': 'iptv'}, // ← 缺 c，只该丢这一项
              {'p': '', 'c': 'x'}, // ← 空 provider
            ],
          }));
      final back = UiPrefs.liveChannelGroups();
      expect(back.containsKey('好的'), isTrue);
      expect(back.containsKey('坏的'), isFalse, reason: '★ 坏组被跳过');
      expect(back['半坏']!.length, 1,
          reason: '★★ 半坏的组只丢坏项，好的那项留下（不让整组作废）');
    });

    test('★★ 整份是垃圾 ⇒ 空 Map（不抛、不炸）', () {
      UiPrefs.debugResetForTest();
      UiPrefs.set(UiPrefs.liveChannelGroupsKey, '{{{ 不是 json');
      expect(UiPrefs.liveChannelGroups(), isEmpty);
    });

    test('★★ 传空 Map ⇒ 键被**清除**（不留垃圾键）', () {
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveChannelGroups({
        '常看': [const LiveChannelRef('a', '1')],
      });
      expect(UiPrefs.liveChannelGroups(), isNotEmpty);
      UiPrefs.setLiveChannelGroups({});
      expect(UiPrefs.liveChannelGroups(), isEmpty);
    });

    test('★★★ v1 与 v2 是**两个独立的键**（老数据不被新写入破坏）', () {
      // 这条是"回退成本 = 删 v2 的键，v1 原样还在"的机器可验版本
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({
        '老组': ['iptv'],
      });
      UiPrefs.setLiveChannelGroups({
        '新组': [const LiveChannelRef('iptv', 'cctv1')],
      });
      expect(UiPrefs.liveSourceGroups()['老组'], ['iptv'],
          reason: '★★★ 写 v2 不许碰 v1');
      expect(UiPrefs.liveChannelGroups()['新组'], isNotNull);
      // 反过来：清 v2 也不许动 v1
      UiPrefs.setLiveChannelGroups({});
      expect(UiPrefs.liveSourceGroups()['老组'], ['iptv'],
          reason: '★★★ 清 v2 不许碰 v1（回退路径必须是安全的）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ④ 频道搜索判据
  // ═════════════════════════════════════════════════════════════════════
  group('④ liveChannelMatchesQuery —— 跨源频道搜索', () {
    test('★ 空查询 ⇒ 全部放行（不筛）', () {
      expect(liveChannelMatchesQuery('', 'CCTV1', 'IPTV'), isTrue);
      expect(liveChannelMatchesQuery('   ', 'CCTV1', 'IPTV'), isTrue);
    });

    test('★★ 按**频道名**匹配（Owner 要的正是这个）', () {
      expect(liveChannelMatchesQuery('体育', 'CCTV5 体育', 'IPTV'), isTrue);
      expect(liveChannelMatchesQuery('体育', 'CCTV1 综合', 'IPTV'), isFalse);
    });

    test('★★ 大小写不敏感（CCTV / cctv 都要命中）', () {
      expect(liveChannelMatchesQuery('cctv', 'CCTV1', 'IPTV'), isTrue);
      expect(liveChannelMatchesQuery('CCTV', 'cctv1', 'IPTV'), isTrue);
      expect(liveChannelMatchesQuery('CcTv', 'cCtV1', 'IPTV'), isTrue);
    });

    test('★★ 也匹配**源名**（用户可能记得"某个源的那个台"）', () {
      expect(liveChannelMatchesQuery('iptv', '随便什么台', 'IPTV'), isTrue);
    });

    test('★ 首尾空格被 trim（用户手打常带空格）', () {
      expect(liveChannelMatchesQuery('  体育  ', 'CCTV5 体育', 'IPTV'), isTrue);
    });

    test('★★ 不做拼音/模糊（仓库里没有拼音表，硬加会引入假命中）', () {
      // 「tiyu」不是「体育」的任何子串 ⇒ 必须**不**命中（这是有意的）
      expect(liveChannelMatchesQuery('tiyu', 'CCTV5 体育', 'IPTV'), isFalse,
          reason: '★ 明确不做拼音匹配 —— 判据只认字面子串');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑤ 三态判据（Owner「首次打开显示 0 个」的真修法）
  // ═════════════════════════════════════════════════════════════════════
  group('⑤ liveLoadPhaseOf —— loading / failed / empty / ready 必须分开', () {
    test('★ loading 优先（还在拉就别说"没有源"）', () {
      expect(
        liveLoadPhaseOf(loading: true, failed: false, channelCount: 0),
        LiveLoadPhase.loading,
      );
      // ★ 即使已经有频道，loading 仍然算 loading（首帧一致性）
      expect(
        liveLoadPhaseOf(loading: true, failed: false, channelCount: 50),
        LiveLoadPhase.loading,
      );
    });

    test('★★ failed 与 empty 必须分开（这是"0 个"的真因）', () {
      /*
       * 改前两者都画成「没有可用的直播源」⇒ 用户被引导去设置里启用源，
       * 而他的源明明是启用的（真实原因是核心未就绪导致取数抛异常）。
       */
      expect(
        liveLoadPhaseOf(loading: false, failed: true, channelCount: 0),
        LiveLoadPhase.failed,
      );
      expect(
        liveLoadPhaseOf(loading: false, failed: false, channelCount: 0),
        LiveLoadPhase.empty,
      );
    });

    test('★ 有频道 ⇒ ready', () {
      expect(
        liveLoadPhaseOf(loading: false, failed: false, channelCount: 1),
        LiveLoadPhase.ready,
      );
    });

    test('★★★ 失败态**不**被"有频道"掩盖（宁可显示旧列表+重试）', () {
      /*
       * 判据顺序：loading → failed → empty → ready。
       * 若把 failed 放在 channelCount 之后，一次失败但还留着旧 _groups 时
       * 会显示"正常"，用户不知道数据已经陈旧。
       * ⇒ 现在 failed 优先 ⇒ 明确让他重试。
       */
      expect(
        liveLoadPhaseOf(loading: false, failed: true, channelCount: 30),
        LiveLoadPhase.failed,
        reason: '★ failed 优先于 ready —— 陈旧数据要明说',
      );
    });
  });
}
