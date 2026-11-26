import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/design.dart';
import '../print_bridge.dart';

class PrintLogDialog extends StatefulWidget {
  const PrintLogDialog({super.key, required this.logs});

  final List<Json> logs;

  @override
  State<PrintLogDialog> createState() => _PrintLogDialogState();
}

class _PrintLogDialogState extends State<PrintLogDialog> {
  static const _timeWidth = 176.0;
  static const _rowPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
  static const _muted = TextStyle(color: WorkstationStyle.muted, fontSize: 12);

  bool _copying = false;
  String? _copyFeedback;

  Future<void> _copyLogs() async {
    setState(() {
      _copying = true;
      _copyFeedback = null;
    });
    final text = widget.logs.reversed
        .map((entry) {
          return '${_displayTime(entry)}  ${entry['message'] ?? ''}';
        })
        .join('\n');
    String feedback;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      feedback = '已复制全部日志';
    } on PlatformException {
      feedback = '复制失败，请重试';
    }
    if (!mounted) return;
    setState(() {
      _copying = false;
      _copyFeedback = feedback;
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: WorkstationStyle.card,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    constraints: const BoxConstraints(maxWidth: 656, maxHeight: 520),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(WorkstationStyle.radius),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: WorkstationStyle.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.history,
                  color: WorkstationStyle.accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      namesRoute: true,
                      header: true,
                      child: const Text(
                        '打印记录',
                        style: TextStyle(
                          color: WorkstationStyle.ink,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _copyFeedback ?? '打印服务运行事件 · 最新在前',
                        style: _muted,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: '复制全部日志',
                child: TextButton.icon(
                  onPressed: widget.logs.isEmpty || _copying ? null : _copyLogs,
                  style: TextButton.styleFrom(
                    foregroundColor: WorkstationStyle.accent,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: const Icon(Icons.content_copy_outlined, size: 16),
                  label: const Text('复制'),
                ),
              ),
              IconButton(
                tooltip: '关闭弹窗',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
                color: WorkstationStyle.muted,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(child: _body()),
        ],
      ),
    ),
  );

  Widget _body() => LayoutBuilder(
    builder: (context, constraints) {
      final logs = widget.logs;
      final timeWidth =
          _timeWidth * MediaQuery.textScalerOf(context).scale(12) / 12;
      final timeColumnWidth = constraints.maxWidth >= timeWidth + 240
          ? timeWidth
          : null;
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: WorkstationStyle.line),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: logs.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '暂无打印记录',
                  textAlign: TextAlign.center,
                  style: _muted,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ColoredBox(
                    color: WorkstationStyle.bg,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: timeColumnWidth,
                            child: const Text('本机时间', style: _muted),
                          ),
                          if (timeColumnWidth != null)
                            const Text('事件', style: _muted),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: WorkstationStyle.line),
                  Flexible(
                    child: SelectionArea(
                      child: ListView.separated(
                        shrinkWrap: true,
                        primary: false,
                        padding: EdgeInsets.zero,
                        itemCount: logs.length,
                        separatorBuilder: (context, index) => const Divider(
                          height: 1,
                          color: WorkstationStyle.line,
                        ),
                        itemBuilder: (context, index) => _logRow(
                          logs[logs.length - 1 - index],
                          timeColumnWidth: timeColumnWidth,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      );
    },
  );

  String _displayTime(Json entry) {
    final rawTime = '${entry['at'] ?? ''}';
    return DateTime.tryParse(rawTime)
            ?.toLocal()
            .toIso8601String()
            .replaceFirst('T', ' ') ??
        rawTime;
  }

  Widget _logRow(Json entry, {required double? timeColumnWidth}) {
    final time = Text(
      _displayTime(entry),
      style: _muted.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final message = Text(
      '${entry['message'] ?? ''}',
      style: const TextStyle(
        color: WorkstationStyle.ink,
        fontSize: 14,
        height: 1.4,
      ),
    );
    return Padding(
      padding: _rowPadding,
      child: timeColumnWidth != null
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: timeColumnWidth - 12, child: time),
                const SizedBox(width: 12),
                Expanded(child: message),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [time, const SizedBox(height: 4), message],
            ),
    );
  }
}
