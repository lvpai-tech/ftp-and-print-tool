import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../manual_batch/card_decoder.dart';
import '../manual_batch/card_tail_recognizer.dart';
import '../photo_normalizer.dart';
import 'workstation_form_dialog.dart';

typedef CardCodeChoice = ({String? code, String? barcode});

Future<CardCodeChoice?> showCardTailDialog(
  BuildContext context, {
  required Future<Uint8List> Function() readPhoto,
  required String guidance,
  String? sourcePath,
  Future<void> Function(int byteLength, String tail)? onRecognized,
  bool allowUse = false,
  String useLabel = '核对后用于补录',
}) => showDialog<CardCodeChoice>(
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
  int? _pointer;
  String _result = '';
  String? _candidate;
  String? _barcode;
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

  Future<({String? code, Object? error})> _scanResult(
    Future<String?> scan,
  ) async {
    try {
      return (code: await scan, error: null);
    } catch (error) {
      return (code: null, error: error);
    }
  }

  Future<void> _recognize() async {
    final selection = _selection;
    if (_reading || _start != null) return;
    setState(() {
      _reading = true;
      _result = '';
      _candidate = null;
      _barcode = null;
    });
    String result;
    String? code;
    String? barcode;
    try {
      final (bytes, _, _) = await _photo;
      final sourcePath = widget.sourcePath;
      final tailScan = CardTailRecognizer.shared.recognize(
        bytes,
        selection,
        sourcePath: sourcePath,
      );
      String? tail;
      if (selection == null) {
        final scans = await Future.wait([
          _scanResult(tailScan),
          _scanResult(
            compute(
              (request) => decodeCardBytes(
                normalizeJpegPrimary(request.$1, sourcePath: request.$2),
                barcodeOnly: true,
              ),
              (bytes, sourcePath),
            ),
          ),
        ]);
        tail = scans.first.code;
        barcode = scans.last.code;
        if (tail == null && barcode == null) {
          final error = scans.first.error ?? scans.last.error;
          if (error != null) throw error;
        }
      } else {
        tail = await tailScan;
      }
      code = tail ?? barcode;
      result = tail != null && barcode != null
          ? '候选尾号 $tail，已同时读到条形码。'
          : barcode != null
          ? '已识别条形码中的完整取片码，请核对卡面。'
          : tail != null
          ? '候选尾号 $tail'
          : '未能确认取片码，可框选完整六位数字重试。';
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
        _candidate = code;
        _barcode = barcode;
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
          key: const ValueKey('card-tail-image'),
          size: display,
          child: MouseRegion(
            cursor: _reading
                ? SystemMouseCursors.wait
                : SystemMouseCursors.precise,
            child: RawGestureDetector(
              gestures: {
                EagerGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      EagerGestureRecognizer
                    >(() => EagerGestureRecognizer(), (_) {}),
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (_reading ||
                      _pointer != null ||
                      event.buttons != kPrimaryButton) {
                    return;
                  }
                  setState(() {
                    _pointer = event.pointer;
                    _start = normalize(event.localPosition);
                    _selection = null;
                    _result = '';
                    _candidate = null;
                    _barcode = null;
                  });
                },
                onPointerMove: (event) {
                  if (event.pointer != _pointer) return;
                  setState(() {
                    _selection = Rect.fromPoints(
                      _start!,
                      normalize(event.localPosition),
                    );
                  });
                },
                onPointerUp: (event) {
                  if (event.pointer != _pointer) return;
                  final selection = Rect.fromPoints(
                    _start!,
                    normalize(event.localPosition),
                  );
                  setState(() {
                    _pointer = null;
                    _start = null;
                    _selection =
                        selection.width * display.width >= 4 &&
                            selection.height * display.height >= 4
                        ? selection
                        : null;
                  });
                },
                onPointerCancel: (event) {
                  if (event.pointer != _pointer) return;
                  setState(() {
                    _pointer = null;
                    _start = null;
                    _selection = null;
                  });
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
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
            ),
          ),
        ),
      );
    },
  );

  void _clearSelection() => setState(() {
    _selection = null;
    _result = '';
    _candidate = null;
    _barcode = null;
  });

  Widget _recognitionStatus(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = _selection != null;
    final (icon, title, detail) = switch ((_reading, _result.isNotEmpty)) {
      (true, _) => (
        Icons.document_scanner_outlined,
        '正在识别取片码',
        selected ? '正在读取选框内的六位尾号' : '正在同时读取条形码和六位尾号',
      ),
      (_, true) => (
        _candidate == null ? Icons.info_outline : Icons.check_circle_outline,
        _candidate == null ? '请核对卡面' : '识别结果',
        _result,
      ),
      _ => (
        selected ? Icons.crop_free : Icons.info_outline,
        selected ? '已框选识别区域' : '扫描卡面',
        selected ? '请确认选框包含完整六位数字。' : '可直接扫描，也可拖动框选完整六位数字。',
      ),
    };
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _reading
              ? colors.primaryContainer.withValues(alpha: 0.45)
              : colors.surfaceContainerLow,
          border: Border.all(
            color: _reading ? colors.primaryContainer : colors.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                spacing: 10,
                children: [
                  Icon(icon, color: colors.primary, size: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colors.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected && _start == null && !_reading)
                    TextButton(
                      onPressed: _clearSelection,
                      child: const Text('清除选框'),
                    ),
                ],
              ),
              SizedBox(
                height: 3,
                child: _reading && !MediaQuery.disableAnimationsOf(context)
                    ? const LinearProgressIndicator(
                        key: ValueKey('card-tail-scan-progress'),
                        borderRadius: BorderRadius.all(Radius.circular(3)),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoPlaceholder(BuildContext context, Object? error) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Icon(
              error == null
                  ? Icons.image_outlined
                  : Icons.broken_image_outlined,
              color: error == null ? colors.primary : colors.error,
              size: 28,
            ),
            Text(
              error == null ? '正在加载照片' : '照片加载失败',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            if (error != null)
              Text(
                error is StateError ? error.message : '请检查原图和访问权限',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              )
            else if (!MediaQuery.disableAnimationsOf(context))
              const SizedBox(
                width: 96,
                child: LinearProgressIndicator(
                  key: ValueKey('card-tail-photo-progress'),
                  minHeight: 3,
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final photoHeight = (MediaQuery.sizeOf(context).height * 0.5).clamp(
      144.0,
      440.0,
    );
    return FutureBuilder(
      future: _photo,
      builder: (context, snapshot) => WorkstationFormDialog(
        title: '识别取片码',
        titleLeading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.document_scanner_outlined,
            color: colors.onPrimaryContainer,
            size: 20,
          ),
        ),
        width: 720,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Container(
              height: photoHeight,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(14),
              ),
              child: switch (snapshot.data) {
                final photo? => _image(photo.$2, photo.$3),
                null => _photoPlaceholder(context, snapshot.error),
              },
            ),
            if (!snapshot.hasError) _recognitionStatus(context),
            if (widget.guidance.isNotEmpty)
              Text(
                widget.guidance,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: _reading || _start != null || !snapshot.hasData
                ? null
                : _recognize,
            icon: Icon(
              _selection == null
                  ? Icons.document_scanner_outlined
                  : Icons.crop_free,
              size: 18,
            ),
            label: Text(_selection == null ? '整图识别' : '识别尾号'),
          ),
          if (widget.allowUse && _candidate != null)
            FilledButton.tonal(
              onPressed: () =>
                  Navigator.pop(context, (code: _candidate, barcode: _barcode)),
              child: Text(widget.useLabel),
            ),
        ],
      ),
    );
  }
}
