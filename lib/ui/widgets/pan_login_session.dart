import 'package:material_ui/material_ui.dart' show visibleForTesting;

import '../../core/ffi.dart' show SourinCore;

typedef PanLoginCommandCaller = Future<dynamic> Function(
  String command,
  Map<String, dynamic> arguments,
);

@visibleForTesting
PanLoginCommandCaller? debugPanLoginCommandCaller;

const panLoginRequestTimeout = Duration(seconds: 15);

class PanLoginFlowException implements Exception {
  const PanLoginFlowException(this.message);
  final String message;
}

String panLoginErrorText(Object error, {required String fallback}) =>
    error is PanLoginFlowException ? error.message : fallback;

Future<Map<String, dynamic>> callPanLoginCommand(
  String command,
  Map<String, dynamic> arguments, {
  PanLoginCommandCaller? caller,
}) async {
  final value =
      await (caller ?? debugPanLoginCommandCaller ?? SourinCore.callAsync)(
        command,
        arguments,
      ).timeout(panLoginRequestTimeout);
  if (value is! Map) {
    throw const PanLoginFlowException('没有读到完整登录结果，请重新检测或重新登录');
  }
  return value.cast<String, dynamic>();
}

class PanLoginRecognition {
  const PanLoginRecognition({required this.account});
  final String account;
}

/// This verifies local backend recognition, not the remote session's validity.
Future<PanLoginRecognition> verifyPanLoginRecognition(
  String kind, {
  PanLoginCommandCaller? caller,
}) async {
  final status = await callPanLoginCommand(
    'pan_auth_status',
    {},
    caller: caller,
  );
  final accounts = status['accounts'];
  if (accounts is List) {
    for (final row in accounts) {
      if (row is! Map || row['kind'] != kind) continue;
      if (row['keyringAvailable'] != true) {
        throw const PanLoginFlowException('系统钥匙串不可用，登录状态未能保存；请检查系统钥匙串后重新登录');
      }
      if (row['expired'] == true) {
        throw const PanLoginFlowException('应用识别到的登录已过期，请重新登录');
      }
      if (row['loggedIn'] == true && row['expired'] == false) {
        return PanLoginRecognition(account: '${row['account'] ?? ''}');
      }
    }
  }
  throw const PanLoginFlowException('登录已完成，但应用尚未识别账号；请点击「重新检测」，或改用扫码登录');
}

Future<PanLoginRecognition> saveAndRecognizePanWebLogin({
  required String kind,
  required String cookie,
  PanLoginCommandCaller? caller,
  bool Function()? isCurrent,
}) async {
  void ensureCurrent() {
    if (isCurrent != null && !isCurrent()) {
      throw const PanLoginFlowException('本次登录已取消');
    }
  }

  ensureCurrent();
  final saved = await callPanLoginCommand('pan_save_credential', {
    'kind': kind,
    'account': '',
    'cookie': cookie,
  }, caller: caller);
  ensureCurrent();
  if (saved['ok'] != true) {
    throw const PanLoginFlowException('登录态未能保存，请重新检测或重新登录');
  }
  final recognized = await verifyPanLoginRecognition(kind, caller: caller);
  ensureCurrent();
  return recognized;
}
