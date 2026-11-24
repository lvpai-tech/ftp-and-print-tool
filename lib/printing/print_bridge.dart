import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../workstation_storage.dart';
import 'print_enrollment.dart';

typedef Json = Map<String, dynamic>;

class PrintBridgeResultError extends StateError {
  PrintBridgeResultError(super.message, this.resultCode);

  final int resultCode;
}

/// Flutter 与独立打印进程之间的私有管道。断开后禁止自动重试送打。
class PrintBridge extends ChangeNotifier {
  Process? _process;
  final _pending = <int, Completer<dynamic>>{};
  int _sequence = 0;
  Json snapshot = {};
  String? error;
  String? systemPrinterIssue;
  bool storageUnavailable = false;
  Future<void>? _starting;
  Future<void>? _checkingPrinters;
  bool connected = false;
  bool working = false;
  bool starting = false;
  bool get configured => snapshot['configured'] == true;
  Json get state => Map<String, dynamic>.from(snapshot['state'] ?? {});
  Json get config => Map<String, dynamic>.from(snapshot['config'] ?? {});
  List<Json> get jobs => (state['jobPage']?['list'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  bool get printing => state['printBusy'] == true;
  bool get busy => working || printing;

  void showError(String message) {
    error = message;
    notifyListeners();
  }

  /// 发布包只使用随包内核；开发通过显式环境变量指定仓库内核。
  Future<void> start({
    String? personnelToken,
    Uri? personnelOrigin,
    String? scenicId,
  }) {
    if (connected) return Future.value();
    return _starting ??= _start(
      personnelToken: personnelToken,
      personnelOrigin: personnelOrigin,
      scenicId: scenicId,
    ).whenComplete(() => _starting = null);
  }

  Future<void> _start({
    required String? personnelToken,
    required Uri? personnelOrigin,
    required String? scenicId,
  }) async {
    starting = true;
    error = null;
    storageUnavailable = false;
    notifyListeners();
    try {
      final printOrigin = PrintEnrollment.origin;
      if (personnelOrigin != null &&
          personnelOrigin.origin != printOrigin.origin) {
        throw StateError('打印服务须与工作台登录使用同一网关地址');
      }
      if (personnelOrigin != null &&
          (personnelToken == null || scenicId == null)) {
        throw StateError('请先登录并选择工作景区');
      }
      final runtime = resolvePrintRuntime();
      final node =
          Platform.environment['LVPAI_PRINT_NODE'] ??
          p.join(runtime, Platform.isWindows ? 'node.exe' : 'node');
      final script = p.join(runtime, 'src', 'flutter-bridge.cjs');
      if (!File(node).existsSync() || !File(script).existsSync()) {
        throw StateError('打印内核未打包，请使用构建脚本生成完整客户端');
      }
      final String configPath;
      try {
        configPath =
            Platform.environment['PRINT_AGENT_CONFIG'] ??
            p.join(
              (await getApplicationSupportDirectory()).path,
              'printing',
              'config.json',
            );
        if (Platform.isMacOS) {
          final configDirectory = await File(configPath).parent
              .create(recursive: true);
          await checkWritableDirectory(configDirectory);
        }
      } on FileSystemException {
        if (!Platform.isMacOS) rethrow;
        throw WorkstationStorageError('无法读写打印数据目录，请检查目录权限和可用空间后重试。');
      } on MissingPlatformDirectoryException {
        if (!Platform.isMacOS) rethrow;
        throw WorkstationStorageError('找不到打印数据目录，请恢复当前用户的数据目录后重试。');
      }
      await checkMacWorkstationCredentials();
      final Map<String, String> credentials;
      try {
        credentials = await PrintEnrollment.credentials();
      } on PlatformException catch (error) {
        if (!Platform.isMacOS) rethrow;
        throw macWorkstationStorageError(error);
      }
      _process = await Process.start(
        node,
        [script],
        workingDirectory: runtime,
        environment: {
          'PRINT_AGENT_CONFIG': configPath,
          'LVPAI_PRINT_APP_ROOT': runtime,
          'PRINT_AGENT_BASE': printOrigin
              .replace(path: '/api/operation')
              .toString(),
        },
      );
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _receive,
            onError: (_) => _disconnected(),
            onDone: _disconnected,
          );
      // stderr 仅用于启动失败提示；不写入令牌、请求或图片内容。
      _process!.stderr.transform(utf8.decoder).listen((text) {
        error = text.trim();
        notifyListeners();
      });
      await call('initialize', [
        credentials,
        if (personnelToken != null)
          {'token': personnelToken, 'scenicId': scenicId},
      ]);
      connected = true;
      notifyListeners();
      if (Platform.isMacOS) unawaited(checkSystemPrinters());
    } catch (e) {
      storageUnavailable = e is WorkstationStorageError;
      error ??= e is StateError
          ? e.message
          : '$e'.replaceFirst(RegExp(r'^Bad state:\s*'), '');
      final process = _process;
      if (process != null) {
        await process.stdin.close();
        await process.exitCode;
        _process = null;
      }
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> checkSystemPrinters() {
    if (!connected) return Future.value();
    return _checkingPrinters ??= _checkSystemPrinters().whenComplete(
      () => _checkingPrinters = null,
    );
  }

  Future<void> _checkSystemPrinters() async {
    try {
      final printers = await call('listPrinters') as List<dynamic>;
      systemPrinterIssue = printers.isEmpty
          ? 'macOS 未找到打印机。请在「系统设置 → 打印机与扫描仪」添加后重新检查。'
          : null;
    } catch (_) {
      systemPrinterIssue = '无法读取 macOS 打印机列表。请检查系统打印服务和打印机连接后重试。';
    }
    notifyListeners();
  }

  void _receive(String line) {
    try {
      final message = jsonDecode(line) as Json;
      if (message['event'] == 'startupError' && message['code'] == 'ELOCKED') {
        error = '已有打印服务在运行。请从系统托盘打开原工作台。若原窗口已退出，请等当前打印完成后重新打开。';
        return;
      }
      if (message['event'] == 'snapshot') {
        snapshot = Map<String, dynamic>.from(message['data']);
        notifyListeners();
        return;
      }
      final pending = _pending.remove(message['id']);
      if (pending == null) return;
      if (message['error'] != null) {
        final error = message['error'] as String;
        final code = message['resultCode'];
        pending.completeError(
          code is int ? PrintBridgeResultError(error, code) : StateError(error),
        );
      } else {
        final data = message['data'];
        if (data is Map && data.containsKey('state')) {
          final map = Map<String, dynamic>.from(data);
          // 未配置快照自带 configured:false，必须保留；勿一律写成 true。
          if (!map.containsKey('configured')) {
            map['configured'] = true;
          }
          snapshot = map;
          notifyListeners();
        }
        pending.complete(data);
      }
    } catch (_) {
      _disconnected();
    }
  }

  void _disconnected() {
    connected = false;
    error ??= '打印内核连接已断开。若有送打，请先核对实物与服务端状态，再重新启动。';
    for (final pending in _pending.values) {
      pending.completeError(StateError(error!));
    }
    _pending.clear();
    notifyListeners();
  }

  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (_process == null) throw StateError('打印内核未启动');
    final id = ++_sequence;
    final result = Completer<dynamic>();
    _pending[id] = result;
    _process!.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'args': args}),
    );
    // 打印操作可能持续较久；超时只报未知，不再次发起。
    return result.future.timeout(
      const Duration(hours: 2),
      onTimeout: () {
        _pending.remove(id);
        throw StateError('操作超时，结果未知；请核对工单与实物，勿重复送打');
      },
    );
  }

  Future<dynamic> run(String method, [List<dynamic> args = const []]) async {
    if (busy &&
        !(method == 'autoPrint' && args.length == 1 && args[0] == false)) {
      throw StateError('请等待当前操作完成');
    }
    if (busy) return call(method, args);
    working = true;
    error = null;
    notifyListeners();
    try {
      return await call(method, args);
    } catch (_) {
      // 业务失败由界面弹窗展示，不写入顶栏 error（顶栏仅留给连接/内核故障）。
      rethrow;
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> blockNewWork() async {
    if (starting) await waitUntilIdle();
    if (connected) await call('lockPersonnel');
  }

  Future<void> waitUntilIdle() async {
    final idle = Completer<void>();
    void check() {
      if (!starting && !busy && !idle.isCompleted) idle.complete();
    }

    addListener(check);
    try {
      check();
      await idle.future.timeout(const Duration(minutes: 20));
    } finally {
      removeListener(check);
    }
  }

  Future<void> shutdown() async {
    if (busy) throw StateError('打印处理中，请等待完成后退出');
    final process = _process;
    if (connected) await call('shutdown');
    if (process == null) return;
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 30));
    _process = null;
    connected = false;
    snapshot = {};
    error = null;
    systemPrinterIssue = null;
    storageUnavailable = false;
    notifyListeners();
  }

  /// 环境变量优先；否则可执行文件旁，再尝试 macOS `Contents/Resources/print-runtime`。
  static String resolvePrintRuntime() {
    final fromEnv = Platform.environment['LVPAI_PRINT_RUNTIME'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return fromEnv;
    }
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final beside = p.join(exeDir, 'print-runtime');
    if (Directory(beside).existsSync()) {
      return beside;
    }
    if (Platform.isMacOS) {
      final inResources = p.normalize(
        p.join(exeDir, '..', 'Resources', 'print-runtime'),
      );
      if (Directory(inResources).existsSync()) {
        return inResources;
      }
    }
    return beside;
  }
}
