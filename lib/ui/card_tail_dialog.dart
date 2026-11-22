import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../manual_batch/card_tail_recognizer.dart';

Future<void> showCardTailDialog(
  BuildContext context, {
  required Future<Uint8List> Function() readPhoto,
  required String guidance,
}) => showDialog<void>(
  context: context,
  builder: (_) => _CardTailDialog(readPhoto: readPhoto, guidance: guidance),
);

class _CardTailDialog extends StatefulWidget {
  const _CardTailDialog({required this.readPhoto, required this.guidance});

  final Future<Uint8List> Function() readPhoto;
  final String guidance;

  @override
  State<_CardTailDialog> createState() => _CardTailDialogState();
}

class _CardTailDialogState extends State<_CardTailDialog> {
  late final _photo = _loadPhoto();
  Rect? _selection;
  Offset? _start;
  String _result = '';
  bool _reading = false;

  Future<(Uint8List, Uint8List, Size)> _loadPhoto() async {
    final bytes = await widget.readPhoto();
    final (preview, size) = await compute(cardTailPreview, bytes);
    return (bytes, preview, size);
  }

  Future<void> _recognize() async {
    final selection = _selection;
    if (_reading || selection == null || _start != null) return;
    setState(() {
      _reading = true;
      _result = '';
    });
    String result;
    try {
      final (bytes, _, _) = await _photo;
      final tail = await CardTailRecognizer.shared.recognize(bytes, selection);
      result = tail == null ? '未能确认四位尾号，请调整选区后重试' : '候选尾号 $tail';
    } on StateError catch (error) {
      result = error.message;
    } catch (_) {
      result = '尾号识别运行失败，请重试或检查客户端安装';
    }
    if (mounted) {
      setState(() {
        _reading = false;
        _result = result;
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
      title: const Text('识别取片卡尾号'),
      content: SizedBox(
        width: 620,
        height: screen.height * 0.55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('拖动框住卡面上的四位数字。'),
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
      ],
    );
  }
}
