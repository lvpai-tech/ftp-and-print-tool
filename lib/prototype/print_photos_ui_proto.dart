import 'package:material_ui/material_ui.dart';

import '../printing/ui/design.dart' as print_ui;
import '../ui/design.dart';
import 'print_photos_variant_a.dart';
import 'print_photos_variant_b.dart';
import 'print_photos_variant_c.dart';

/// Throwaway print-photos UI prototype.
/// Question: which layout best fits auto-print + counter find + exceptions?
/// Three structurally different variants, switchable from the floating bar.
class PrintPhotosUiProto extends StatefulWidget {
  const PrintPhotosUiProto({super.key});

  @override
  State<PrintPhotosUiProto> createState() => _PrintPhotosUiProtoState();
}

class _PrintPhotosUiProtoState extends State<PrintPhotosUiProto> {
  /// A=指挥台 B=队列优先 C=双焦
  var variant = 'A';
  var autoPrint = true;
  var filter = 'pending';
  var hitVisible = false;
  final selected = <int>{};
  final search = TextEditingController();
  var lastAction = '打开原型';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void _setVariant(String v) {
    setState(() {
      variant = v;
      lastAction = '切换到方案 $v';
    });
  }

  void _toast(String message) {
    setState(() => lastAction = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1400),
        ),
      );
  }

  void _toggleSelect(int id) {
    setState(() {
      if (!selected.add(id)) selected.remove(id);
      lastAction = '选择变更 → ${selected.length} 单';
    });
  }

  void _onSearch() {
    setState(() {
      hitVisible = true;
      lastAction = '找单「${search.text.trim().isEmpty ? '578' : search.text.trim()}」→ 命中 #578';
    });
    if (variant != 'C') {
      _toast('已定位 #578（原型）');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep body under tight Expanded constraints — AnimatedSwitcher/Stack
    // loosens height and blanked the page in Windows release builds.
    return Scaffold(
      backgroundColor: const Color(0xfff4f7f8),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _banner(),
          Expanded(child: _body()),
          _stateStrip(),
          _switcher(),
        ],
      ),
    );
  }

  Widget _banner() {
    return Container(
      width: double.infinity,
      color: const Color(0xff0f1c22),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      child: const Row(
        children: [
          Text(
            'PROTOTYPE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '打印照片桌面端 UI · 复用 WorkstationStyle / 打印色板 · 假数据，不接 PrintBridge',
              style: TextStyle(color: Color(0xffd7e4ea), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    return switch (variant) {
      'B' => PrintPhotosVariantB(
        autoPrint: autoPrint,
        selected: selected,
        filter: filter,
        search: search,
        onToggleAuto: (v) => setState(() {
          autoPrint = v;
          lastAction = v ? '开启自动打印' : '关闭自动打印';
        }),
        onToggleSelect: _toggleSelect,
        onFilter: (f) => setState(() {
          filter = f;
          lastAction = '筛选=$f';
        }),
        onSearch: _onSearch,
        onAction: _toast,
      ),
      'C' => PrintPhotosVariantC(
        autoPrint: autoPrint,
        search: search,
        hitVisible: hitVisible,
        onToggleAuto: (v) => setState(() {
          autoPrint = v;
          lastAction = v ? '开启自动打印' : '关闭自动打印';
        }),
        onSearch: _onSearch,
        onAction: _toast,
      ),
      _ => PrintPhotosVariantA(
        autoPrint: autoPrint,
        selected: selected,
        search: search,
        onToggleAuto: (v) => setState(() {
          autoPrint = v;
          lastAction = v ? '开启自动打印' : '关闭自动打印';
        }),
        onToggleSelect: _toggleSelect,
        onClearSelect: () => setState(() {
          selected.clear();
          lastAction = '取消选择';
        }),
        onSearch: _onSearch,
        onAction: _toast,
      ),
    };
  }

  Widget _stateStrip() {
    return Container(
      width: double.infinity,
      color: const Color(0xff0f1c22),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        'state = { variant: $variant, autoPrint: $autoPrint, selected: ${selected.length}, filter: $filter, hitVisible: $hitVisible, lastAction: $lastAction }',
        style: const TextStyle(
          color: Color(0xff9fb0b9),
          fontSize: 11,
          fontFamily: 'Consolas',
          fontFamilyFallback: ['Menlo', 'monospace'],
        ),
      ),
    );
  }

  Widget _switcher() {
    Widget chip(String id, String label) {
      final on = variant == id;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: on ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _setVariant(id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? WorkstationStyle.ink : const Color(0xffc5d4db),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xeb0f1c22),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .28),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 12, right: 6),
                  child: Text(
                    '切换方案',
                    style: TextStyle(color: Color(0xff9fb0b9), fontSize: 12),
                  ),
                ),
                chip('A', 'A 指挥台'),
                chip('B', 'B 队列'),
                chip('C', 'C 双焦'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny theme aligned with workstation + print accent.
ThemeData printPhotosProtoTheme() {
  return ThemeData(
    useMaterial3: true,
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'sans-serif',
    ],
    colorScheme: ColorScheme.fromSeed(
      seedColor: print_ui.accent,
      surface: WorkstationStyle.card,
    ),
    scaffoldBackgroundColor: const Color(0xfff4f7f8),
    dividerColor: WorkstationStyle.line,
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}
