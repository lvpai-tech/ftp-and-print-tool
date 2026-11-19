import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 追加日志每次flush；完整行损坏则拒绝启动，掉电留下的末尾半行截断后恢复。
/// 独占锁防止两个客户端同时处理同一个来源/目标队列。
class QueueJournal {
  // Apple/POSIX 文件锁以进程为单位，同一 isolate 另加登记，避免重复打开释放原锁。
  static final Set<String> _openFiles = {};
  final File file;
  String? _leasePath;
  RandomAccessFile? _lock;
  RandomAccessFile? _writer;
  Future<void> _tail = Future.value();
  QueueJournal(this.file);

  Future<List<Map<String, dynamic>>> open() async {
    if (_leasePath != null) throw StateError('队列日志已经打开');
    await file.parent.create(recursive: true);
    final canonical = p.join(
      await file.parent.resolveSymbolicLinks(),
      p.basename(file.path),
    );
    if (!_openFiles.add(canonical)) {
      throw FileSystemException('同一队列已由当前应用打开', file.path);
    }
    _leasePath = canonical;
    try {
      _lock = await File('${file.path}.lock').open(mode: FileMode.append);
      await _lock!.lock(FileLock.exclusive);
      final bytes = await file.exists() ? await file.readAsBytes() : <int>[];
      final last = bytes.lastIndexOf(10);
      final validLength = last + 1;
      final text = utf8.decode(bytes.sublist(0, validLength));
      final records = text
          .split('\n')
          .where((line) => line.isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      _writer = await file.open(mode: FileMode.append);
      if (validLength != bytes.length) await _writer!.truncate(validLength);
      return records;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> append(Map<String, dynamic> event) {
    final data = utf8.encode('${jsonEncode(event)}\n');
    _tail = _tail.then((_) async {
      await _writer!.writeFrom(data);
      await _writer!.flush();
    });
    return _tail;
  }

  Future<void> close() async {
    try {
      await _tail;
    } finally {
      try {
        await _writer?.close();
      } finally {
        _writer = null;
        try {
          await _lock?.close();
        } finally {
          _lock = null;
          if (_leasePath != null) _openFiles.remove(_leasePath);
          _leasePath = null;
        }
      }
    }
  }
}
