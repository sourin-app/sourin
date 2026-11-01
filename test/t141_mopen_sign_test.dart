// ═══════════════════════════════════════════════════════════════════════
//  T8 · 站源弹幕签名/协议构造单测（MopenDanmuClient 纯函数）
// ═══════════════════════════════════════════════════════════════════════
//
// # 对拍样例的出处（这就是"取证样例对拍"，不是自说自话）
// ```text
// .probe/mopen-danmu-probe2-result.md（round-2，lead 授权补证，只读取证）：
//   token = 720fd82e14d1c7bd398a416cdd092dfd（_m_h5_tk 下划线前半段）
//   t     = 1793497040（秒）
//   body  = n6 模板逐字
//   sign  = ad7ba13cf76396d9551b0b74884a863b（python hashlib.md5 独立算出，
//           与 Dart package:crypto **跨实现**对拍）
//   ★ 该请求网关回 ret=["SUCCESS::调用成功"] —— 签名口径实证成立。
// ```
// MTOP h5 标准签名：sign = md5(token + '&' + t + '&' + appKey + '&' + data)。

import 'dart:convert';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku_mopen.dart';

void main() {
  group('① body 模板逐字（n6 17 串拼接）', () {
    test('与 probe 归档的请求 body 逐字一致', () {
      final body = MopenDanmuClient.buildBody(
        vid: 'XNjU3MzA0MTkxNg',
        mat: 1,
        ctime: 1793497040,
      );
      expect(
        body,
        '{"ctime": 1793497040, "ctype": 10004, "cver": "v1.0",'
        ' "guid": "NJnMGnrls3wCAXQaiNsMGIsY", "mat": 1, "mcount": 1,'
        ' "pid": 0, "sver": "3.1.0", "vid": "XNjU3MzA0MTkxNg"}',
      );
    });

    test('取证常量逐字（appKey/secret/guid 是公开常量，benchmark ③）', () {
      expect(MopenDanmuClient.appKey, '24679788');
      // secret 在 MTOP 口径实证后不再参与签名，但它是 T2 取证锚点——钉住
      expect(MopenDanmuClient.secret, 'MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr');
      expect(MopenDanmuClient.guid, 'NJnMGnrls3wCAXQaiNsMGIsY');
      expect(MopenDanmuClient.apiName, 'mopen.youku.danmu.list');
    });
  });

  group('② sign 对拍（跨实现：Dart vs python hashlib，round-2 实证口径）', () {
    test('probe round-2 归档的 (token,t,body) ⇒ 归档 sign（网关回 SUCCESS）', () {
      final body = MopenDanmuClient.buildBody(
        vid: 'XNjU3MzA0MTkxNg',
        mat: 1,
        ctime: 1793497040,
      );
      expect(
        MopenDanmuClient.signFor(
            '720fd82e14d1c7bd398a416cdd092dfd', 1793497040, body),
        'ad7ba13cf76396d9551b0b74884a863b',
      );
    });

    test('首跳无令牌：空 token 也构成确定性签名，且 token 确实参与签名串', () {
      final body = MopenDanmuClient.buildBody(
        vid: 'XNjU3MzA0MTkxNg',
        mat: 1,
        ctime: 1793497035,
      );
      final s = MopenDanmuClient.signFor('', 1793497035, body);
      expect(s.length, 32);
      expect(
        s,
        isNot(MopenDanmuClient.signFor(
            '720fd82e14d1c7bd398a416cdd092dfd', 1793497035, body)),
        reason: 'token 参签 ⇒ 空/有 token 的签名必然不同',
      );
    });

    test('签名敏感性：data / t / token 任一变化 ⇒ sign 必变', () {
      final body = MopenDanmuClient.buildBody(
        vid: 'XTestVid0001',
        mat: 2,
        ctime: 1700000000,
      );
      final other = MopenDanmuClient.buildBody(
        vid: 'XTestVid0001',
        mat: 3,
        ctime: 1700000000,
      );
      final base = MopenDanmuClient.signFor('tok', 1700000000, body);
      expect(base, isNot(MopenDanmuClient.signFor('tok', 1700000000, other)));
      expect(base, isNot(MopenDanmuClient.signFor('tok', 1700000001, body)));
      expect(base, isNot(MopenDanmuClient.signFor('tok2', 1700000000, body)));
    });
  });

  group('③ MD5 实现自证（RFC 1321 标准向量）', () {
    // signFor 用的是 package:crypto 的同一条 md5——用标准向量钉住它，
    // 保证"跨实现对拍期望值"与"实现"用的是同一条 MD5 语义。
    test("md5('') = d41d8cd98f00b204e9800998ecf8427e", () {
      expect(md5.convert(utf8.encode('')).toString(),
          'd41d8cd98f00b204e9800998ecf8427e');
    });

    test("md5('abc') = 900150983cd24fb0d6963f7d28e17f72", () {
      expect(md5.convert(utf8.encode('abc')).toString(),
          '900150983cd24fb0d6963f7d28e17f72');
    });
  });

  group('④ URL 构造（n6 两个前缀串逐字拼接）', () {
    test('与 probe round-2 实际请求 URL 逐字一致', () {
      final uri = MopenDanmuClient.buildUri(
        t: 1793497040,
        sign: 'ad7ba13cf76396d9551b0b74884a863b',
      );
      expect(
        uri.toString(),
        'https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/'
        '?jsv=2.7.0&appKey=24679788&t=1793497040'
        '&api=mopen.youku.danmu.list&v=1.0&type=originaljson'
        '&dataType=jsonp&timeout=20000&jsonpIncPrefix=utility'
        '&sign=ad7ba13cf76396d9551b0b74884a863b',
      );
    });
  });

  group('⑤ vid 提取（用户输入 → vid）', () {
    test('裸 vid 原样收（X 开头、≥10 位）', () {
      expect(MopenDanmuClient.vidFromInput('XNjU3MzA0MTkxNg'),
          'XNjU3MzA0MTkxNg');
    });

    test('完整播放链接取 id_ 段', () {
      expect(
        MopenDanmuClient.vidFromInput(
            'https://v.youku.com/v_show/id_XNjU3MzA0MTkxNg==.html'),
        'XNjU3MzA0MTkxNg==',
        reason: '只做提取不做规范化（vid 规范形态未取证，用户给什么带什么）',
      );
    });

    test('无效输入 ⇒ null（不编 vid）', () {
      expect(MopenDanmuClient.vidFromInput(''), isNull);
      expect(MopenDanmuClient.vidFromInput('   '), isNull);
      expect(MopenDanmuClient.vidFromInput('随便一句话'), isNull);
      expect(MopenDanmuClient.vidFromInput('X短'), isNull);
    });
  });
}
