import 'package:flutter_test/flutter_test.dart';

/// Reads one balanced body or argument list from comment-stripped source.
/// [marker] includes its opening delimiter, so named parameters cannot be
/// mistaken for a method body. Quoted delimiters do not affect the boundary.
String sourceBlock(String source, String marker) {
  final open = marker[marker.length - 1];
  final close = switch (open) {
    '{' => '}',
    '(' => ')',
    _ => throw ArgumentError.value(marker, 'marker'),
  };
  final start = source.indexOf(marker);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing source block: $marker');
  expect(source.lastIndexOf(marker), start,
      reason: 'Source block must be unambiguous: $marker');
  final begin = start + marker.length;
  var depth = 1;
  String? quote;
  for (var i = begin; i < source.length; i++) {
    final c = source[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == open) {
      depth++;
    } else if (c == close && --depth == 0) {
      return source.substring(begin, i);
    }
  }
  fail('Unbalanced source block: $marker');
}
