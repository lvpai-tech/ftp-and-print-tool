import 'dart:async';
import 'dart:collection';

/// 按申请顺序分配整机并发名额。
class UploadSlots {
  UploadSlots(this._available) : assert(_available > 0);

  int _available;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_available > 0) {
      _available--;
    } else {
      final ready = Completer<void>();
      _waiting.addLast(ready);
      await ready.future;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isEmpty) {
        _available++;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}
