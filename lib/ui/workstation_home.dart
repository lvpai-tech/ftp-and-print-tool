import 'package:material_ui/material_ui.dart';

const workstationBackground = Color(0xfff5f7fb);
const workstationInk = Color(0xff192943);

enum WorkModule {
  upload(
    '上传照片',
    '手动上传，也可以自动上传新照片。',
    '去上传',
    Icons.cloud_upload_outlined,
    Color(0xff2056b9),
    [Color(0xff0f2449), Color(0xff18366c), Color(0xff265ba2)],
  ),
  print(
    '打印照片',
    '手动打印，也可以自动打印新任务。',
    '去打印',
    Icons.print_outlined,
    Color(0xff6741a5),
    [Color(0xff271b45), Color(0xff3a275d), Color(0xff69489a)],
  );

  const WorkModule(
    this.label,
    this.description,
    this.action,
    this.icon,
    this.color,
    this.gradient,
  );
  final String label, description, action;
  final IconData icon;
  final Color color;
  final List<Color> gradient;

  Color get tint => Color.lerp(Colors.white, color, .10)!;
}

class WorkstationMark extends StatelessWidget {
  const WorkstationMark({super.key});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(11),
    child: Image.asset(
      'assets/branding/zhenji-brand.png',
      width: 40,
      height: 40,
      fit: BoxFit.cover,
    ),
  );
}

class WorkstationHome extends StatelessWidget {
  const WorkstationHome({
    super.key,
    required this.uploadStatus,
    required this.printStatus,
    required this.uploadActive,
    required this.printActive,
    required this.onOpen,
  });

  final String uploadStatus, printStatus;
  final bool uploadActive, printActive;
  final ValueChanged<WorkModule> onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= 800;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          wide ? 40 : 16,
          wide ? 57 : 28,
          wide ? 40 : 16,
          28,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1110),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '照片工作台',
                  style: TextStyle(
                    fontSize: wide ? 48 : 34,
                    height: 1.16,
                    color: workstationInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 13),
                const Text(
                  '上传和打印可以同时进行。',
                  style: TextStyle(fontSize: 15, color: Color(0xff52637c)),
                ),
                SizedBox(height: wide ? 40 : 22),
                LayoutBuilder(
                  builder: (context, available) {
                    final cards = [
                      for (final module in WorkModule.values)
                        _ModuleCard(
                          module: module,
                          status: module == WorkModule.upload
                              ? uploadStatus
                              : printStatus,
                          active: module == WorkModule.upload
                              ? uploadActive
                              : printActive,
                          illustrate: wide
                              ? available.maxWidth >= 910
                              : available.maxWidth >= 460,
                          onTap: () => onOpen(module),
                        ),
                    ];
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: cards.first),
                              const SizedBox(width: 22),
                              Expanded(child: cards.last),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              cards.first,
                              const SizedBox(height: 14),
                              cards.last,
                            ],
                          );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.module,
    required this.status,
    required this.active,
    required this.illustrate,
    required this.onTap,
  });

  final WorkModule module;
  final String status;
  final bool active;
  final bool illustrate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(22));
    final light = module == WorkModule.upload
        ? const Color(0xffaecbff)
        : const Color(0xffd9c1ff);
    return Material(
      color: module.gradient.first,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: light.withValues(alpha: .55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomLeft,
            end: Alignment.topRight,
            colors: module.gradient,
          ),
        ),
        child: InkWell(
          key: ValueKey('open-${module.name}'),
          onTap: onTap,
          hoverColor: Colors.white.withValues(alpha: .06),
          focusColor: Colors.white.withValues(alpha: .13),
          child: Padding(
            padding: illustrate
                ? const EdgeInsets.symmetric(horizontal: 26, vertical: 30)
                : const EdgeInsets.all(19),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white24),
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Icon(module.icon, size: 23, color: light),
                            ),
                          ),
                          SizedBox(height: illustrate ? 24 : 13),
                          Text(
                            module.label,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: illustrate ? 30 : 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            module.description,
                            style: const TextStyle(
                              color: Color(0xffe5eaf8),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (illustrate)
                      ExcludeSemantics(
                        child: CustomPaint(
                          size: const Size(142, 146),
                          painter: _ModuleIllustration(module, light),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: illustrate ? 28 : 17),
                const Divider(height: 1, color: Colors.white24),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      active ? Icons.circle : Icons.circle_outlined,
                      size: 9,
                      color: active ? const Color(0xffa8f1d0) : light,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        status,
                        key: ValueKey('status-${module.name}'),
                        style: const TextStyle(
                          color: Color(0xffe5eaf8),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      module.action,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white12,
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModuleIllustration extends CustomPainter {
  const _ModuleIllustration(this.module, this.accent);

  final WorkModule module;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = accent.withValues(alpha: .12);
    final outline = Paint()
      ..color = accent.withValues(alpha: .68)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final subtle = Paint()
      ..color = Colors.white.withValues(alpha: .10)
      ..style = PaintingStyle.stroke;
    final center = size.center(Offset.zero);
    canvas.drawCircle(center, 68, subtle);
    canvas.drawCircle(
      center,
      57,
      Paint()..color = Colors.white.withValues(alpha: .045),
    );

    void block(
      double left,
      double top,
      double width,
      double height,
      double radius,
    ) {
      final shape = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, height),
        Radius.circular(radius),
      );
      canvas.drawRRect(shape, fill);
      canvas.drawRRect(shape, outline);
    }

    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), outline);

    if (module == WorkModule.upload) {
      for (final y in [50.0, 73.0, 96.0]) {
        block(24, y, 89, 18, 5);
        canvas.drawCircle(Offset(34, y + 9), 2, Paint()..color = accent);
        line(44, y + 9, 62, y + 9);
      }
      const points = [
        Offset(94, 69),
        Offset(94, 25),
        Offset(84, 35),
        Offset(94, 25),
        Offset(104, 35),
      ];
      for (var i = 1; i < points.length; i++) {
        canvas.drawLine(points[i - 1], points[i], outline);
      }
    } else {
      block(47, 28, 48, 43, 5);
      line(56, 42, 83, 42);
      line(56, 50, 77, 50);
      block(24, 61, 94, 40, 9);
      canvas.drawCircle(const Offset(37, 74), 2, Paint()..color = accent);
      block(43, 85, 56, 34, 5);
      final image = Path()
        ..moveTo(50, 111)
        ..lineTo(64, 98)
        ..lineTo(73, 106)
        ..lineTo(80, 100)
        ..lineTo(92, 111);
      canvas.drawPath(image, outline);
    }
  }

  @override
  bool shouldRepaint(_ModuleIllustration oldDelegate) =>
      module != oldDelegate.module || accent != oldDelegate.accent;
}
