// 2026-10-17（task-32 ①）诊断：几个 bilibili 接口在本机的**真实状态码**
//
// 背景：Lead 说 search/type 在风控下回 412，所以加了 season 兜底。
// 但兜底只在 `hits.isEmpty` 时才走 —— 所以先要弄清**本机现在到底哪个接口可用**。
// 若 search 在本机是通的，那 season 兜底就**永远不会被触发**，
// 真机就证明不了它（这是必须如实报告的结论，不能拿 search 的成功冒充 season 的成功）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

Future<String> _status(String label, String url, {String? referer}) async {
  try {
    final client = io.HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    if (referer != null) req.headers.set('Referer', referer);
    final r = await req.close().timeout(const Duration(seconds: 15));
    final body = await r.transform(utf8.decoder).join();
    final head = body.trimLeft();
    final isHtml = head.startsWith('<!') || head.toLowerCase().startsWith('<html');
    final preview = head.length > 120 ? head.substring(0, 120) : head;
    final line = '$label  http=${r.statusCode}  len=${body.length}  html=$isHtml';
    print('[EP] $line');
    if (isHtml) print('[EP]    body=${preview.replaceAll(' ', ' ')}');
    return '${r.statusCode}';
  } catch (e) {
    print('[EP] $label  EXCEPTION $e');
    return 'ERR';
  }
}

void main() {
  test('各接口真实状态码', () async {
    const ref = 'https://www.bilibili.com/';
    // ① 搜索（风控重灾区）
    await _status('search/type  ',
        'https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83',
        referer: ref);
    // ② 搜索 all/v2
    await _status('search/all/v2',
        'https://api.bilibili.com/x/web-interface/search/all/v2?keyword=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83',
        referer: ref);
    // ③ season（Lead 新增的兜底链路）
    await _status('pgc/season  ', 'https://api.bilibili.com/pgc/view/web/season?season_id=26801',
        referer: ref);
    // ④ season 搜索
    await _status('pgc/search  ',
        'https://api.bilibili.com/x/web-interface/search/type?search_type=media_bangumi&keyword=%E9%AC%BC%E7%81%AD%E4%B9%8B%E5%88%83',
        referer: ref);
    // ⑤ 弹幕 XML（真正要的东西）
    await _status('comment.xml ', 'https://comment.bilibili.com/125463156.xml', referer: ref);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
