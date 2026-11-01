// ═══════════════════════════════════════════════════════════════════════
//  N-23018 · 夸克 21001「file not found」分类门禁（2026-11-01，lead 批复③）
// ═══════════════════════════════════════════════════════════════════════
//
// # 现场事实（sourin-2026-11-01.log，真机实锤）
// ```text
// 14:39:13  取下载地址 HTTP 400 code=23018 file size limit[e2d3230f…]
// 14:39:40  取下载地址 HTTP 404 {"code":21001,"message":"file not found [e2d3230f…]"}
// 同一个 fid 27 秒内"存在但超限"→"不存在"：我们上次解析的 purge 把它删了，
// save 对同名文件去重回吐了刚删的 fid（竞态）——根因与修复在 pan_drive.rs。
// ```
//
// # 本文件守什么（Dart 侧分类）
// ```text
// ① 真机 404(21001) 原文 ⇒ shareFileGone 档（"分享的这个文件已不存在"），
//    canRetry=false（重试无出路，与 23018 同类），headline/nextStep 逐字。
// ② Rust 自愈失败后的终态文案（"文件已不存在（code=21001 file not found）…"）
//    同样归 shareFileGone —— 两层文案一个归类。
// ③ 不许误伤：裸 404（无 21001/file not found）维持 source + 可重试（既有行为）；
//    23018 不归这档；单特征（只有码或只有短语）不命中。
// ④ 登录按钮钉死：该错误文本与归类结果都**不得**满足登录判据
//    （unauthorized / 登录已失效 / permission 档）—— Owner 已登录却看到
//    「登录」按钮（截图）就是本次报障的一半。
// ```
//
// # 证红
// 把 classify 里 `lower.contains('21001') && lower.contains('file not found')`
// 这条分支删掉/改恒 false ⇒ ①② 必红。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 真机日志原文（14:39:40，逐字；内部无敏感值——fid 是网盘文件 id 片段）
const String realLog404 =
    '夸克网盘 取下载地址返回 HTTP 404 Not Found：{"status":404,"code":21001,'
    '"message":"file not found [e2d3230f98f54014aeffdaae5967dc32]","req_id":'
    '"9f2tu9-2b7a614afce4ec","timestamp":1793515180}…（共 145 字节）';

/// Rust 自愈失败后的终态文案（pan_drive.rs play 的 21001 分支）
const String selfHealExhausted =
    '夸克网盘 文件已不存在（code=21001 file not found），无法播放，请换一条线路';

void main() {
  group('① 真机 404(21001) ⇒ shareFileGone 档', () {
    test('★ 日志原文逐字归类：headline/nextStep/canRetry', () {
      final f = PlaybackErrorText.classify(realLog404);
      expect(f.kind, PlaybackFailureKind.shareFileGone,
          reason: '★ 21001 = 文件已不存在，不许落到 source（归因错档）');
      expect(f.canRetry, isFalse,
          reason: '★ 文件没了，重试无出路（与 23018 同类）——'
              '给一颗点了必然失败的按钮等于把用户困在原地');
      expect(f.headline, '分享的这个文件已不存在');
      expect(f.nextStep, contains('换一条线路'));
    });

    test('★ Rust 自愈失败的终态文案同样归 shareFileGone', () {
      final f = PlaybackErrorText.classify(selfHealExhausted);
      expect(f.kind, PlaybackFailureKind.shareFileGone);
      expect(f.canRetry, isFalse);
    });

    test('★ 三个档位文案纪律：不含内部地址 / 宿主类名 / 端口', () {
      final f = PlaybackErrorText.classify(realLog404);
      final visible = '${f.headline}${f.nextStep}';
      expect(visible.contains(RegExp(r'127\.0\.0\.1|localhost')), isFalse);
      expect(visible.contains(RegExp(r'SourinCoreException|Exception')), isFalse);
      expect(visible.contains(RegExp(r':\d{4,}')), isFalse,
          reason: '端口不许进用户可见文案');
    });
  });

  group('② 不许误伤（既有行为零变化）', () {
    test('★ 裸 404（无 21001 双特征）⇒ 维持 source + 可重试', () {
      final f = PlaybackErrorText.classify(
          '取流失败: HTTP 404 Not Found（上游返回空）');
      expect(f.kind, PlaybackFailureKind.source,
          reason: '普通 404 是"地址没了"，不是"网盘文件没了"——维持既有归类');
      expect(f.canRetry, isTrue);
    });

    test('★ 23018 超限文案不归 shareFileGone（两码两事）', () {
      final f = PlaybackErrorText.classify(
          '夸克网盘 取下载地址失败（code=23018）：download file size limit'
          '（该文件超出账号单文件下载上限）');
      expect(f.kind, isNot(PlaybackFailureKind.shareFileGone),
          reason: '★ 超限是账号现实、文件还在；21001 是文件没了——不许混');
    });

    test('★ 单特征不命中（防裸数字/裸短语误伤）', () {
      // 路径里恰好有 "21001"（如视频 id/日期串）
      expect(
        PlaybackErrorText.classify('取流失败: https://cdn.example.com/v/21001/a.m3u8')
            .kind,
        isNot(PlaybackFailureKind.shareFileGone),
      );
      // 只有 "file not found" 没有 21001（别家网盘的 404 文案）
      expect(
        PlaybackErrorText.classify('取流失败: file not found').kind,
        isNot(PlaybackFailureKind.shareFileGone),
      );
    });
  });

  group('③ 登录按钮钉死（本次报障的另一半）', () {
    test('★ 21001 文本与归类都不得满足登录判据（unauthorized/登录已失效/permission）',
        () {
      // player_page 的登录按钮判据（_isAuthError）：_errorKind=='unauthorized'
      // 或文本含 'unauthorized'/'登录已失效'。本条把"这个错误点不亮登录按钮"
      // 钉在分类层：owner_page 判据所需的两个特征都不许出现。
      for (final text in <String>[realLog404, selfHealExhausted]) {
        expect(text.toLowerCase().contains('unauthorized'), isFalse,
            reason: '★ 文本含 unauthorized 会点亮「登录」按钮——'
                'Owner 已登录却看到登录按钮正是本次报障');
        expect(text.contains('登录已失效'), isFalse);
        final f = PlaybackErrorText.classify(text);
        expect(f.kind, isNot(PlaybackFailureKind.permission),
            reason: '★ permission 档的 nextStep 指向换源，且它是'
                '"源站要求会员/地区"——文件不存在不是权限问题');
      }
    });
  });
}
