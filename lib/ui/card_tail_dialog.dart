import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../manual_batch/card_tail_recognizer.dart';

Future<String?> showCardTailDialog(
  BuildContext context, {
  required Future<Uint8List> Function() readPhoto,
  required String guidance,
  String? sourcePath,
  Future<void> Function(int byteLength, String tail)? onRecognized,
  bool allowUse = false,
  String useLabel = '核对后用于补录',
}) => showDialog<String>(
  context: context,
  builder: (_) => _CardTailDialog(
    readPhoto: readPhoto,
    guidance: guidance,
    sourcePath: sourcePath,
    onRecognized: onRecognized,
    allowUse: allowUse,
    useLabel: useLabel,
  ),
);

class _CardTailDialog extends StatefulWidget {
  const _CardTailDialog({
    required this.readPhoto,
    required this.guidance,
    required this.sourcePath,
    required this.onRecognized,
    required this.allowUse,
    required this.useLabel,
  });

  final Future<Uint8List> Function() readPhoto;
  final String guidance;
  final String? sourcePath;
  final Future<void> Function(int byteLength, String tail)? onRecognized;
  final bool allowUse;
  final String useLabel;

  @override
  State<_CardTailDialog> createState() => _CardTailDialogState();
}

class _CardTailDialogState extends State<_CardTailDialog> {
  late final _photo = _loadPhoto();
  Rect? _selection;
  Offset? _start;
  String _result = '';
  String? _candidate;
  bool _reading = false;

  Future<(Uint8List, Uint8List, Size)> _loadPhoto() async {
    final bytes = await widget.readPhoto();
    final sourcePath = widget.sourcePath;
    final (preview, size) = await compute(
      (bytes) => cardTailPreview(bytes, sourcePath: sourcePath),
      bytes,
    );
    return (bytes, preview, size);
  }

  Future<void> _recognize() async {
    final selection = _selection;
    if (_reading || selection == null || _start != null) return;
    setState(() {
      _reading = true;
      _result = '';
      _candidate = null;
    });
    String result;
    String? tail;
    try {
      final (bytes, _, _) = await _photo;
      tail = await CardTailRecognizer.shared.recognize(
        bytes,
        selection,
        sourcePath: widget.sourcePath,
      );
      result = tail == null ? '未能确认尾号，请调整选区后重试' : '候选尾号 $tail';
      final report = widget.onRecognized;
      if (tail != null && report != null) {
        try {
          await report(bytes.length, tail);
          result = '候选尾号 $tail · 已上报后台';
        } catch (_) {
          result = '候选尾号 $tail · 后台未确认，请重试识别以上报';
        }
      }
    } on StateError catch (error) {
      result = error.message;
    } catch (_) {
      result = '尾号识别运行失败，请重试或检查客户端安装';
    }
    if (mounted) {
      setState(() {
        _reading = false;
        _result = result;
        _candidate = tail;
      });
    }
  }

  Widget _image(Uint8List preview, Size imageSize) => LayoutBuilder(
    builder: (context, limits) {
      final display = applyBoxFit(
        BoxFit.contain,
        imageSize,
        limits.biggest,
      ).destination;
      Offset normalize(Offset position) => Offset(
        (position.dx / display.width).clamp(0.0, 1.0),
        (position.dy / display.height).clamp(0.0, 1.0),
      );
      final selection = _selection;
      return Center(
        child: SizedBox.fromSize(
          size: display,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: _reading
                ? null
                : (details) => setState(() {
                    _start = normalize(details.localPosition);
                    _selection = null;
                    _result = '';
                    _candidate = null;
                  }),
            onPanUpdate: _reading
                ? null
                : (details) {
                    final start = _start;
                    if (start == null) return;
                    setState(
                      () => _selection = Rect.fromPoints(
                        start,
                        normalize(details.localPosition),
                      ),
                    );
                  },
            onPanEnd: _reading ? null : (_) => setState(() => _start = null),
            onPanCancel: _reading ? null : () => setState(() => _start = null),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(preview, fit: BoxFit.fill),
                if (selection != null)
                  Positioned.fromRect(
                    rect: Rect.fromLTRB(
                      selection.left * display.width,
                      selection.top * display.height,
                      selection.right * display.width,
                      selection.bottom * display.height,
                    ),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x223b82f6),
                          border: Border.all(
                            color: Colors.lightBlueAccent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('识别取片码'),
      scrollable: true,
      content: SizedBox(
        width: 620,
        height: screen.height * 0.55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('拖动框住卡面上的完整六位尾号。'),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder(
                future: _photo,
                builder: (context, snapshot) {
                  final photo = snapshot.data;
                  if (photo != null) return _image(photo.$2, photo.$3);
                  if (snapshot.hasError) {
                    final error = snapshot.error;
                    return Center(
                      child: Text(
                        error is StateError
                            ? error.message
                            : '照片无法读取，请检查原图和访问权限',
                      ),
                    );
                  }
                  return const Center(child: CircularProgressIndicator());
                },
              ),
            ),
            const SizedBox(height: 8),
            if (_reading || _result.isNotEmpty)
              Semantics(
                liveRegion: true,
                child: Text(_reading ? '正在识别…' : _result),
              ),
            Text(widget.guidance),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _reading || _start != null || _selection?.isEmpty != false
              ? null
              : _recognize,
          child: const Text('识别尾号'),
        ),
        if (widget.allowUse && _candidate != null)
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, _candidate),
            child: Text(widget.useLabel),
          ),
      ],
    );
  }
}
