// task-65 / 批次 B：弹幕**聚合**（Owner 第 9 条）
//
// Owner 原话（逐字）：
// ```text
// > 有些网站本身也提供弹幕,我们要支持弹幕的聚合
// ```
//
// # 这份测试要钉住什么
// ```text
// 改前 `_loadDanmakuNamed` 那串 if 是**互斥**的：
//   绑了外部视频站 ⇒ `_loadBiliDanmaku(cid); return;`   ← dan-api 那条被 return 掉
// ⇒ 「插件给一份 + 导入源给一份」时只有一份被载入。那是二选一，不是聚合。
//
// 这里测的是**聚合器本身**（纯函数，不碰网络）：
//   ① 两路都进来（不是只有一路）
//   ② 按时间重排（轨道分配器要求入参有序）
//   ③ 重复去掉，但**同一句话在不同时间点不算重复**
//   ④ 每一路的条数如实（信息面板要能显示"插件 N + 导入 M = K 条"）
//   ⑤ 失败的一路**必须**出现在结果里（不许悄悄吞掉）
// ```
//
// # 故障注入（不许假绿）
// ```text
// 下面 `_mergeBroken` 把"只返回第一路"和"不排序"这两种退化写了出来，
// 用例逐条证明它们**会**让断言变红。跑法见文件末尾的 group ⑤。
// ```
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';

/// 造一条弹幕。`cid` 在渲染层**不参与**任何判断（见 DanmakuComment 的注释），
/// 这里只要求它唯一 —— 用递增计数器保证，不去碰 time 的精度。
int _cidSeq = 0;

DanmakuComment _c(
  double t,
  String text, {
  int color = 0xFFFFFF,
  DanmakuMode mode = DanmakuMode.scroll,
}) =>
    DanmakuComment(
      cid: _cidSeq++,
      time: t,
      text: text,
      mode: mode,
      color: color,
    );

// ---------------------------------------------------------------------------
//  退化实现（故意写坏，用来证明断言不是假绿）
// ---------------------------------------------------------------------------

/// 坏法 ①：只取第一路（= 改前的"二选一"）
DanmakuAggregate _mergeOnlyFirst(List<DanmakuFeedInput> src) {
  final first = src.isEmpty
      ? const DanmakuFeedInput(kind: DanmakuSourceChannel.none)
      : src.first;
  return DanmakuAggregate(
    comments: first.comments,
    feeds: <DanmakuFeedStat>[
      for (final s in src)
        DanmakuFeedStat(kind: s.kind, count: s.comments.length),
    ],
  );
}

/// 坏法 ②：合并了但**不排序**（直接 concat）
DanmakuAggregate _mergeUnsorted(List<DanmakuFeedInput> src) {
  return DanmakuAggregate(
    comments: <DanmakuComment>[for (final s in src) ...s.comments],
    feeds: <DanmakuFeedStat>[
      for (final s in src)
        DanmakuFeedStat(kind: s.kind, count: s.comments.length),
    ],
  );
}

/// 坏法 ③：不统计每一路（只剩一个总数）
DanmakuAggregate _mergeNoFeeds(List<DanmakuFeedInput> src) {
  final r = DanmakuAggregator.merge(src);
  return DanmakuAggregate(comments: r.comments);
}

/// 坏法 ④：失败的那一路被丢掉（不写进 feeds）
DanmakuAggregate _mergeSwallowFailures(List<DanmakuFeedInput> src) {
  final r = DanmakuAggregator.merge(src);
  return DanmakuAggregate(
    comments: r.comments,
    feeds: <DanmakuFeedStat>[
      for (final f in r.feeds)
        if (!f.failed) f,
    ],
  );
}

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  ① 两路都进来
  // ═════════════════════════════════════════════════════════════════════
  group('① 多路合并', () {
    test('★★★ 插件 + 导入源两路都进结果（不是二选一）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, '插件甲'), _c(2, '插件乙')],
          detail: 'demo',
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(3, '导入甲'), _c(4, '导入乙')],
          detail: 'dan-api',
        ),
      ]);

      expect(r.comments.length, 4,
          reason: '★★★ 两路各 2 条 ⇒ 合并后必须是 4 条。'
              '改前那条 `return` 会让这里只有 2 条 —— 这正是 Owner 说的"没聚合"');
      expect(r.feeds.length, 2, reason: '★ 两路都要被记录');
      expect(r.liveFeedCount, 2, reason: '★ 两路都真的供上了数据');
    });

    test('★★ 空输入 ⇒ 空结果，不抛', () {
      final r = DanmakuAggregator.merge(const <DanmakuFeedInput>[]);
      expect(r.comments, isEmpty);
      expect(r.feeds, isEmpty);
      expect(r.isEmpty, isTrue);
    });

    test('★★ 某一路是空列表 ⇒ 仍然记这一路（count=0）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, 'x')],
        ),
        const DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[],
        ),
      ]);
      expect(r.comments.length, 1);
      expect(r.feeds.length, 2, reason: '★ 空的那一路也要出现（否则用户不知道它没给东西）');
      expect(r.liveFeedCount, 1, reason: '★ 只有一路真给了数据');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② 排序
  // ═════════════════════════════════════════════════════════════════════
  group('② 按时间重排', () {
    test('★★★ 交错的两路 ⇒ 合并后时间严格不减', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, 'p1'), _c(5, 'p5'), _c(9, 'p9')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(2, 'i2'), _c(6, 'i6'), _c(10, 'i10')],
        ),
      ]);

      expect(r.comments.map((c) => c.time).toList(),
          <double>[1, 2, 5, 6, 9, 10],
          reason: '★★★ 轨道分配器要求入参按时间有序（见 DanmakuTrackAllocator.layout）。'
              '不排序 ⇒ 后半段弹幕全挤在开头');
    });

    test('★★ 同一时间点的多条：先到的源排前面（稳定）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(3, '插件'), _c(3, '插件2')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(3, '导入')],
        ),
      ]);
      expect(r.comments.map((c) => c.text).toList(),
          <String>['插件', '插件2', '导入'],
          reason: '★ 同 time 时按来源顺序 —— 否则每次跑的顺序可能不同（画面抖动）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ③ 去重
  // ═════════════════════════════════════════════════════════════════════
  group('③ 去重（同时间 + 同正文）', () {
    test('★★★ 两路给了同一条 ⇒ 只留一条', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(12.0, '哈哈'), _c(13.0, '只有插件')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(12.0, '哈哈'), _c(14.0, '只有导入')],
        ),
      ]);

      expect(r.comments.length, 3,
          reason: '★★★ 4 条里 1 条重复 ⇒ 3 条。不去重会出现"重影"（同一句话叠两层）');
      expect(r.deduped, 1, reason: '★ 去掉的条数要如实统计');
      expect(r.sumOfFeeds, 4, reason: '★ 各路条数之和仍是 4（信息面板要显示等式）');
    });

    test('★★ 同一句话在不同时间点 ⇒ **不是**重复', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1.0, '哈哈')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(9.0, '哈哈')],
        ),
      ]);
      expect(r.comments.length, 2,
          reason: '★★ 只按正文去重会误杀 —— 不同时间点的"哈哈"是**不同**弹幕');
    });

    test('★★ 时间差在 0.1s 内 ⇒ 视为同一条（浮点解析容差）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(12.00, '同一句')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(12.04, '同一句')],
        ),
      ]);
      expect(r.comments.length, 1,
          reason: '★ 两路的浮点解析会差零点几毫秒；0.1s 内人眼看不出，按同一条处理');
    });

    test('★ 颜色不同但正文+时间相同 ⇒ 仍是同一条', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(5, '彩色', color: 0xFF0000)],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(5, '彩色', color: 0xFFFFFF)],
        ),
      ]);
      expect(r.comments.length, 1, reason: '★ 颜色不参与判据（同一批弹幕被两个源各抓一遍）');
    });

    // ─────────────────────────────────────────────────────────────────
    //  ★★★ 2026-10-17：**同一路内部的重复必须保留**
    //
    //  # 这是真数据抓出来的缺陷，不是假想的边界
    //  ```text
    //  用真实弹幕（ep11954，9415 条）跑第一版聚合器：
    //    同一路自己给了 9415 条 ⇒ 输出只有 9342 条 —— **少了 73 条**
    //  原因：真实弹幕里"同一时间点同一句话被很多人刷"是常态
    //    （"哈哈" / "前方高能" / 应援词）—— 那是**不同人的不同弹幕**，
    //    只是内容撞了。跨源去重的判据把它们当成重复吃掉了。
    //  ```
    //  ⇒ 判据必须分两段：源内部全留，只在**跨源**时去重。
    // ─────────────────────────────────────────────────────────────────
    test('★★★ 同一路内部重复的弹幕**必须保留**（那是不同人的发言）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[
            _c(12.0, '哈哈'),
            _c(12.0, '哈哈'), // 另一个人也在 12 秒刷了同一句
            _c(12.0, '哈哈'), // 第三个人
          ],
        ),
      ]);

      expect(r.comments.length, 3,
          reason: '★★★ 三句"哈哈"是三个人的三条弹幕 —— 去重成 1 条就是**丢用户数据**。'
              '真数据（ep11954）上这条缺陷会吃掉 73 条');
      expect(r.deduped, 0,
          reason: '★ 单源时"去重"应该是 0 —— 面板上那个数字只该统计**跨源**重复');
      expect(r.feeds.single.count, 3, reason: '★ 这一路自己就是 3 条');
    });

    test('★★★ 跨源去重仍然生效（同一条被两个源各抓一遍 ⇒ 只留一条）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(12.0, '哈哈'), _c(12.0, '哈哈')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(12.0, '哈哈')],
        ),
      ]);

      expect(r.comments.length, 2,
          reason: '★★ 第一路自己 2 条（保留）+ 第二路的 1 条是跨源重复（丢掉）'
              '⇒ 2 条。两个判据都要在：源内全留、跨源去重');
      expect(r.deduped, 1, reason: '★ 只掉了跨源的那 1 条');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ④ 每一路的读数
  // ═════════════════════════════════════════════════════════════════════
  group('④ 每一路的条数（信息面板要显示）', () {
    test('★★★ feeds 里每一路的 count = 该路**自己**的条数（去重前）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, 'a'), _c(2, 'b'), _c(3, 'c')],
          detail: 'demo-provider',
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(2, 'b'), _c(4, 'd')],
          detail: 'dan-api',
        ),
      ]);

      expect(r.feeds[0].count, 3, reason: '★ 插件那路 3 条');
      expect(r.feeds[1].count, 2, reason: '★ 导入那路 2 条');
      expect(r.feeds[0].detail, 'demo-provider', reason: '★ detail 要透传（面板显示来源名）');
      expect(r.comments.length, 4, reason: '★ 去重后 4 条（b 重复）');
      expect(r.sumOfFeeds, 5);
      expect(r.deduped, 1);
    });

    test('★★ summary 在多于一路时是"聚合"口径', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, 'a'), _c(2, 'b')],
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(2, 'b'), _c(3, 'c')],
        ),
      ]);
      expect(r.summary, contains('2 路'), reason: '★ 两路要能看出来是聚合');
      expect(r.summary, contains('插件 2'), reason: '★ 插件那路的条数');
      expect(r.summary, contains('导入源 2'), reason: '★ 导入那路的条数');
      expect(r.summary, contains('3 条'), reason: '★ 合并后 3 条');
      print('summary 实际输出：${r.summary}');
    });

    test('★ 只有一路时 summary 退化成普通摘要（不吹"聚合"）', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(1, 'a')],
        ),
      ]);
      expect(r.summary, isNot(contains('路')), reason: '★ 单路不该说"1 路"');
      expect(r.summary, contains('1 条'));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑤ 失败的一路不许被吞
  // ═════════════════════════════════════════════════════════════════════
  group('⑤ 失败 / 没试的那几路', () {
    test('★★★ 一路失败 ⇒ 它仍出现在 feeds 里，且带错误原文', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, '插件来的')],
        ),
        const DanmakuFeedInput.failed(
          kind: DanmakuSourceChannel.imported,
          error: 'HTTP 401 Unauthorize',
          detail: 'dan-api',
        ),
      ]);

      expect(r.comments.length, 1, reason: '★ 成功的那路照常可用');
      expect(r.feeds.length, 2, reason: '★★★ 失败的那一路**必须**还在列表里');
      expect(r.feeds[1].failed, isTrue);
      expect(r.feeds[1].error, contains('401'),
          reason: '★★ 错误原文照透 —— 否则用户只看到"少了一半"，不知道为什么');
      expect(r.liveFeedCount, 1, reason: '★ 只有 1 路真的供上了数据');
    });

    test('★★ 没试的那一路（如插件不支持弹幕）⇒ loaded=false，不算失败', () {
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        const DanmakuFeedInput.skipped(
          kind: DanmakuSourceChannel.plugin,
          detail: '这个源没有声明弹幕能力',
        ),
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.imported,
          comments: <DanmakuComment>[_c(1, 'a')],
        ),
      ]);
      expect(r.feeds.length, 2);
      expect(r.feeds[0].loaded, isFalse);
      expect(r.feeds[0].failed, isFalse, reason: '★ 没试 ≠ 失败，文案要能区分');
      expect(r.liveFeedCount, 1);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑥ ★ 故障注入：证明上面那些断言**会**变红
  // ═════════════════════════════════════════════════════════════════════
  //
  // 这一段是「不许假绿」的门。它把四种退化实现跑一遍，
  // 逐个证明它们**违反**了上面某条断言。
  group('⑥ 故障注入（坏实现必须被上面的断言抓住）', () {
    final two = <DanmakuFeedInput>[
      DanmakuFeedInput(
        kind: DanmakuSourceChannel.plugin,
        comments: <DanmakuComment>[_c(1, 'p1'), _c(5, 'p5')],
      ),
      DanmakuFeedInput(
        kind: DanmakuSourceChannel.imported,
        comments: <DanmakuComment>[_c(2, 'i2'), _c(6, 'i6')],
      ),
    ];

    test('★★★ 坏法①「只取第一路」⇒ 条数断言会红', () {
      final bad = _mergeOnlyFirst(two);
      expect(bad.comments.length, 2,
          reason: '坏实现只有 2 条（正确实现是 4 条）⇒ '
              '①里的 `expect(r.comments.length, 4)` 必然红');
      expect(bad.comments.length, isNot(4));
    });

    test('★★★ 坏法②「合并但不排序」⇒ 有序断言会红', () {
      final bad = _mergeUnsorted(two);
      final times = bad.comments.map((c) => c.time).toList();
      expect(times, <double>[1, 5, 2, 6], reason: '坏实现的时间轴是乱的');
      final sorted = List<double>.from(times)..sort();
      expect(times, isNot(sorted),
          reason: '★★ ②里的 `expect(..., [1,2,5,6])` 会红 ⇒ 那条断言不是假绿');
    });

    test('★★★ 坏法③「不记每一路」⇒ 读数断言会红', () {
      final bad = _mergeNoFeeds(two);
      expect(bad.feeds, isEmpty);
      expect(bad.sumOfFeeds, 0,
          reason: '★★ ④里的 `expect(r.feeds[0].count, 3)` 会抛 RangeError ⇒ 不是假绿');
    });

    test('★★★ 坏法④「吞掉失败的那一路」⇒ ⑤会红', () {
      final bad = _mergeSwallowFailures(<DanmakuFeedInput>[
        DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: <DanmakuComment>[_c(1, 'a')],
        ),
        const DanmakuFeedInput.failed(
          kind: DanmakuSourceChannel.imported,
          error: 'HTTP 500',
        ),
      ]);
      expect(bad.feeds.length, 1,
          reason: '坏实现只剩 1 路（正确是 2 路）⇒ ⑤里 `expect(r.feeds.length, 2)` 会红');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ⑦ 真实规模（两路各上千条也不慢、不丢）
  // ═════════════════════════════════════════════════════════════════════
  group('⑦ 规模', () {
    test('★★ 两路各 3000 条 ⇒ 6000 条都在，且有序', () {
      final a = <DanmakuComment>[
        for (var i = 0; i < 3000; i++) _c(i.toDouble(), 'A$i'),
      ];
      final b = <DanmakuComment>[
        for (var i = 0; i < 3000; i++) _c(i + 0.5, 'B$i'),
      ];
      final r = DanmakuAggregator.merge(<DanmakuFeedInput>[
        DanmakuFeedInput(kind: DanmakuSourceChannel.plugin, comments: a),
        DanmakuFeedInput(kind: DanmakuSourceChannel.imported, comments: b),
      ]);
      expect(r.comments.length, 6000, reason: '★ 一句不丢（正文都不同）');
      expect(r.deduped, 0);
      for (var i = 1; i < r.comments.length; i++) {
        expect(r.comments[i].time >= r.comments[i - 1].time, isTrue,
            reason: '★ 第 $i 条时间倒退了');
      }
    });
  });
}
