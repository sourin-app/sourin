import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';

List<Episode> _syntheticFiles() => List.generate(7, (index) {
  final number = (index + 1).toString().padLeft(2, '0');
  final reference = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'kind': 'quark',
            'share_id': 'synthetic-contract-share',
            'passcode': '',
            'fid': 'synthetic-file-$number',
          }),
        ),
      )
      .replaceAll('=', '');
  return Episode(
    id: 'csp-quark-contract::panfile:$reference',
    title: index == 2
        ? 'Synthetic S03 E03 (1).mp4'
        : 'Synthetic S03 E$number.mp4',
    index: index,
    flag: 'Quark',
  );
});

void main() {
  Map<String, dynamic>? captured;
  String? command;

  setUp(() {
    captured = null;
    command = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = (cmd, args) async {
      command = cmd;
      captured = Map<String, dynamic>.from(args!);
      return <dynamic>[];
    };
  });

  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugResolveStreamFetcher = null;
  });

  test(
    'typed episode03 copy identity reaches the resolve stream transport',
    () async {
      final files = _syntheticFiles();
      final selected = files[2];
      final request = PlayRequest(
        sourceCode: 'synthetic-line',
        episodeId: selected.id,
        quality: 'original',
        flag: selected.flag,
        episodeTitle: selected.title,
        episodeOrder: selected.index + 1,
        extra: const {'trace': 'synthetic-contract', 'selection': 'episode03'},
      );
      final expected = {
        'source_code': 'synthetic-line',
        'episode_id': selected.id,
        'quality': 'original',
        'flag': 'Quark',
        'episode_title': 'Synthetic S03 E03 (1).mp4',
        'episode_order': 3,
        'extra': {'trace': 'synthetic-contract', 'selection': 'episode03'},
      };

      expect(files, hasLength(7));
      expect(files.map((file) => file.id).toSet(), hasLength(7));
      expect(selected.title, endsWith('(1).mp4'));
      expect(request.toJson(), expected);
      expect(
        await SourinApi.resolveStream(
          'tvbox_agg',
          'csp-quark-contract::synthetic-item',
          req: request,
        ),
        isEmpty,
      );
      expect(command, 'resolve_stream');
      expect(captured, {
        'provider': 'tvbox_agg',
        'id': 'csp-quark-contract::synthetic-item',
        'req': expected,
      });
    },
  );

  test(
    'legacy omitted request remains omitted at the transport boundary',
    () async {
      await SourinApi.resolveStream('tvbox_agg', 'synthetic-item');
      expect(command, 'resolve_stream');
      expect(captured, {'provider': 'tvbox_agg', 'id': 'synthetic-item'});
      expect(captured!.containsKey('req'), isFalse);
    },
  );
}
