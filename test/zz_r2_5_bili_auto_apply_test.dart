// ═══════════════════════════════════════════════════════════════════════
//  R2-#5 · **行为级**判据：起播该不该套用 bili 绑定（三态）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条测试为什么能存在（前因，别删）
// ```text
// 最初判据只写在 `player_page.dart` 的 `_loadDanmakuNamed` 里（两个条件拼一行），
// 于是只能靠 `t73` 的**源码级**判据守。我试过三层夹具去驱动真 PlayerPage
// （假 HttpClient / 假 BiliApi / unawaited+pump），全部撞上 flutter_test 的假时钟
// ⇒ 行为级证据写不出来（三次尝试记在 t73 组2 的缺口注释里）。
// 现在判据被抽成纯函数 `biliCidForAutoApply(...)`（`lib/core/bili/bili_bind.dart`）
// ⇒ 行为可以直接钉，不用起 PlayerPage。
// ```
//
// # 判据（Owner 两次原话的三态）
// ```text
// 没有绑定 / 空绑定        ⇒ 0（永不自动建立）
// 有绑定但 manual=false    ⇒ 0（早期自动流程的残留，不套用）
// 有绑定且 manual=true     ⇒ 该集 cid（"手动绑定的以后就自动更新"）
// manual=true 但该集没 cid ⇒ 0（对齐不上的集不猜）
// ```

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/bili/bili_bind.dart';

BiliBinding _binding({bool withCid = true}) => BiliBinding(
      bvid: 'BV1test0001',
      title: '示例作品',
      aid: 1001,
      episodes: <BiliEpisodeBinding>[
        BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: withCid ? 4242 : 0),
        BiliEpisodeBinding(episodeIndex: 1, page: 2, cid: 4343),
      ],
      manual: false,
      updatedAt: 0,
    );

void main() {
  test('R2-#5 ① 没有绑定 / 空绑定 ⇒ 一次都不套用', () {
    expect(
      biliCidForAutoApply(binding: null, manual: true, episodeIndex: 0),
      0,
      reason: '★ 没有绑定 + 手绑标记 = 数据不一致，也必须 0（不许猜）',
    );
    final empty = BiliBinding(
      bvid: 'BV1x',
      title: 'x',
      aid: 0,
      episodes: const <BiliEpisodeBinding>[],
      manual: true,
      updatedAt: 0,
    );
    expect(biliCidForAutoApply(binding: empty, manual: true, episodeIndex: 0), 0,
        reason: '★ 空绑定没有 cid 可用');
  });

  test('R2-#5 ② manual=false（自动残留）⇒ **不套用**', () {
    expect(
      biliCidForAutoApply(
          binding: _binding(), manual: false, episodeIndex: 0),
      0,
      reason: '★★ 这是 Owner 说的"不要再自动绑定"：早期自动流程建的记录，'
          '起播时一次都不许用（它占了他机器上 34 条绑定里的 32 条）',
    );
  });

  test('R2-#5 ③ manual=true（手绑）⇒ 套用这一集的 cid', () {
    expect(
      biliCidForAutoApply(binding: _binding(), manual: true, episodeIndex: 0),
      4242,
      reason: '★★ 这是 Owner 说的"手动绑定的以后就自动更新"',
    );
    expect(
      biliCidForAutoApply(binding: _binding(), manual: true, episodeIndex: 1),
      4343,
      reason: '★ 集号要对上（对齐错了就绑到别的集去了）',
    );
  });

  test('R2-#5 ④ 手绑但**这一集没有 cid** ⇒ 不猜，返回 0', () {
    expect(
      biliCidForAutoApply(
          binding: _binding(withCid: false), manual: true, episodeIndex: 0),
      0,
      reason: '★ 这一集在站点侧没有对应分 P ⇒ 不许拿别的集顶（宁可不套用）',
    );
    expect(
      biliCidForAutoApply(
          binding: _binding(), manual: true, episodeIndex: 99),
      0,
      reason: '★ 越界的集号同样返回 0',
    );
  });
}
