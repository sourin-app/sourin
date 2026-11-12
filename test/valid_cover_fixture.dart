import 'dart:convert';
import 'dart:typed_data';

const validCoverPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAwCAIAAAD/zu84AAAAYklEQVR4nGNUDp3LQEvARFPTGUYtIAKMxgFBMBpEAx9ELLgkdgbOItUs9/VpmIKjkUwQjAYRQTAaRATBaBARBKNBRBCMBhFBMBpEBMFoEI2AIGIc7cYO/0hmGrWAEKB5EAEASO0FiyW/0WUAAAAASUVORK5CYII=';
final _fixtures = <int, Uint8List>{};

// Preserve the old disk-write window and byte identity with a real PNG.
// Its valid private binary ancillary chunk supplies the requested encoded byte length.
Uint8List validCoverFixture(int encodedLength) => _fixtures.putIfAbsent(
  encodedLength,
  () {
    final png = base64Decode(validCoverPngBase64);
    final dataLength = encodedLength - png.length - 12;
    if (dataLength < 8) throw ArgumentError.value(encodedLength);
    final result = Uint8List(encodedLength);
    final split = png.length - 12;
    result.setRange(0, split, png);
    final view = ByteData.sublistView(result);
    view.setUint32(split, dataLength);
    result.setRange(split + 4, split + 8, ascii.encode('paDd'));
    result.fillRange(split + 8, split + 8 + dataLength, 0x5A);
    result.setRange(split + 8, split + 16, ascii.encode('Padding\x00'));
    var crc = 0xFFFFFFFF;
    for (var i = split + 4; i < split + 8 + dataLength; i++) {
      crc ^= result[i];
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0);
      }
    }
    view.setUint32(split + 8 + dataLength, (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF);
    result.setRange(encodedLength - 12, encodedLength, png.sublist(split));
    return result;
  },
);
