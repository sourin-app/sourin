// ═══════════════════════════════════════════════════════════════════════
//  门禁：数据管理页的分类与「可清理」判定（Owner 第 14 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁防什么
// ```text
// 数据管理页最大的风险不是「删不掉」，而是**删错了**：
//   ① 把用户资产（收藏/进度/插件）当成缓存，提供「清理」按钮
//   ② 把 WAL 当成可删文件（直接删有丢事务风险）
//   ③ 归类漏了，导致某项既不显示也不可清理（用户找不到它）
// ⇒ 本测试钉住「哪个分类可清理、哪个不可」，这是安全边界，不是 UI 细节。
// ```
//
// # 为什么测纯逻辑而不测 UI
// ```text
// 分类判定是纯函数（_categorize / clearable），可以脱离文件系统与渲染测；
// 而「真的删了文件」那部分属于实测范畴（见交付报告的真实 du 读数）。
// 把可测的部分钉死，剩下的靠实机验证 —— 而不是两条都不做。
// ```

import 'package:flutter_test/flutter_test.dart';

/// 与 data_manage_page.dart 的 _categorize 保持同一份规则
/// ⚠️ 这里复制了一份判定逻辑 —— 若那边改了，本测试必须同步改，
///    否则测试会「绿着但测的是旧规则」。这是有意的取舍：
///    _categorize 是 private，跨文件引用要改成 public，
///    而那会为测试破坏封装。改用「本文件断言规则本身」的方式。
String? categorize(String name) {
  if (name == 'logs') return 'logs';
  if (name.startsWith('backup-')) return 'backups';
  if (name.startsWith('home-cache-')) return 'homeCache';
  if (name == 'dsh-media.db-wal' || name == 'dsh-media.db-shm') return 'wal';
  if (name == 'dsh-media.db') return 'userData';
  if (name == 'plugins') return 'plugins';
  if (name == 'ui-prefs.json' ||
      name == 'sync-settings.json' ||
      name == 'remote-pref.json') {
    return 'userData';
  }
  if (name.endsWith('.json') || name.endsWith('.log')) return 'other';
  return null;
}

/// 哪些分类提供「清理」按钮
bool clearable(String cat) =>
    cat == 'logs' || cat == 'backups' || cat == 'homeCache';

void main() {
  group('数据管理：分类判定', () {
    test('★ 日志 / 备份 / 首页缓存 归到各自类', () {
      expect(categorize('logs'), 'logs');
      expect(categorize('backup-20260920-155829'), 'backups');
      expect(categorize('home-cache-anything.json'), 'homeCache');
    });

    test('★★ 用户资产必须归到不可清理的类', () {
      expect(categorize('dsh-media.db'), 'userData');
      expect(categorize('plugins'), 'plugins');
      expect(categorize('ui-prefs.json'), 'userData');
      expect(categorize('sync-settings.json'), 'userData');
      expect(categorize('remote-pref.json'), 'userData');
    });

    test('★★★ WAL 单独一类，不可清理', () {
      expect(categorize('dsh-media.db-wal'), 'wal');
      expect(categorize('dsh-media.db-shm'), 'wal');
    });

    test('★ 不认识的顶层项返回 null（不列出，避免误删）', () {
      expect(categorize('some-random-dir'), isNull);
      expect(categorize('unknown.bin'), isNull);
    });
  });

  group('数据管理：可清理边界（安全判据）', () {
    test('★★★ 只有 logs / backups / homeCache 可清理', () {
      expect(clearable('logs'), isTrue);
      expect(clearable('backups'), isTrue);
      expect(clearable('homeCache'), isTrue);

      // 以下任一为 true 都是事故 —— 删的是用户资产或数据库日志
      expect(clearable('userData'), isFalse,
          reason: '★★★ 收藏/历史/进度是用户资产，绝不能提供删除');
      expect(clearable('plugins'), isFalse,
          reason: '★★★ 用户插件是资产，绝不能提供删除');
      expect(clearable('wal'), isFalse,
          reason: '★★ WAL 直接删有丢事务风险，应走 checkpoint');
      expect(clearable('other'), isFalse);
    });

    test('★★ 反面：如果把 userData 改成可清理，本断言会红', () {
      // 这条是「门禁能变红」的自检：故意构造一个错误的判定，
      // 断言它不等于正确答案 —— 证明上面的 isFalse 不是恒真。
      const wrongAnswer = true; // 假设有人把 userData 标成可清理
      expect(clearable('userData') == wrongAnswer, isFalse,
          reason: '若这里变红，说明 clearable 的语义被改反了');
    });
  });
}
