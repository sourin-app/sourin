import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';

// Same synthetic share URLs/states as t20261101_pan_line_precheck_test.dart.
// Only native transport is replaced: the real panCheck serialization and result
// parsing run, with no DLL, media fixture, account, or network request.
const _items = <({String url, String? pwd})>[
  (url: 'https://pan.quark.cn/s/dead0001', pwd: null),
  (url: 'https://pan.quark.cn/s/lock0002', pwd: 'a"\\+ 中'),
  (url: 'https://pan.baidu.com/s/ok000003', pwd: ''),
];

const _response = <String, dynamic>{
  'results': [
    {
      'url': 'https://pan.quark.cn/s/dead0001',
      'kind': 'quark',
      'shareId': 'dead0001',
      'state': 'bad',
      'summary': '链接失效',
      'cacheable': true,
    },
    {
      'url': 'https://pan.quark.cn/s/lock0002',
      'state': 'locked',
      'summary': '需提取码',
    },
    {
      'url': 'https://pan.baidu.com/s/ok000003',
      'state': 'ok',
      'summary': '',
    },
  ],
  'truncated': 0,
};

void _expectItems(Map<String, dynamic> payload) {
  expect(payload['items'], isA<String>(),
      reason: 'Rust reads items as a JSON string, not a Dart List');
  expect(jsonDecode(payload['items'] as String), [
    {'url': 'https://pan.quark.cn/s/dead0001'},
    {'url': 'https://pan.quark.cn/s/lock0002', 'pwd': 'a"\\+ 中'},
    {'url': 'https://pan.baidu.com/s/ok000003'},
  ]);
}

void _expectResults(List<PanCheckResult> results) {
  expect(results.map((result) => result.url), _items.map((item) => item.url));
  expect(results.map((result) => result.state),
      [PanCheckState.bad, PanCheckState.locked, PanCheckState.ok]);
  expect(results.map((result) => result.summary), ['链接失效', '需提取码', '']);
  expect(results.first.kind, 'quark');
  expect(results.first.shareId, 'dead0001');
  expect(results.first.cacheable, isTrue);
}

void main() {
  final calls = <Map<String, dynamic>>[];
  setUp(() {
    calls.clear();
    final previousTransport = SourinCore.debugCallAsyncTransport;
    final previousFetcher = SourinApi.debugPanCheckFetcher;
    SourinApi.debugPanCheckFetcher = null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'tvbox_pan_check');
      expect(args, isNotNull);
      calls.add(Map<String, dynamic>.from(args!));
      return _response;
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = previousTransport;
      SourinApi.debugPanCheckFetcher = previousFetcher;
    });
  });

  test('pan precheck origin provider reaches the real core transport payload',
      () async {
    final results = await SourinApi.panCheck(
      _items,
      provider: 'csp-pan-origin-fixture',
    );
    expect(calls, hasLength(1));
    final payload = calls.single;
    expect(payload['provider'], 'csp-pan-origin-fixture');
    expect(payload.keys, unorderedEquals(['items', 'provider']));
    _expectItems(payload);
    _expectResults(results);
  });

  test('pan precheck legacy call omits provider and keeps JSON-string items',
      () async {
    final results = await SourinApi.panCheck(_items);
    expect(calls, hasLength(1));
    final payload = calls.single;
    expect(payload.containsKey('provider'), isFalse);
    expect(payload.keys, ['items']);
    _expectItems(payload);
    _expectResults(results);
  });
}
